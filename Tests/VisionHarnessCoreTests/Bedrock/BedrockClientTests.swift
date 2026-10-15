import XCTest
@testable import VisionHarnessCore

// MARK: - Test doubles

/// A value shared with `@Sendable` closures.
private final class BedrockTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var current: Value { lock.lock(); defer { lock.unlock() }; return stored }
    @discardableResult
    func update<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&stored) }
}

/// Counts requests: 1 for the first, 2 for the second …
private final class BedrockTestCounter: @unchecked Sendable {
    private let box = BedrockTestBox(0)
    func next() -> Int { box.update { $0 += 1; return $0 } }
}

/// An in-memory Bedrock behind `URLSession`: every request is recorded and answered by the handler a
/// test installs (real event-stream frames, AWS error replies, hung and cut streams). Used through a
/// session whose `protocolClasses` is just this class.
final class FakeBedrock: URLProtocol, @unchecked Sendable {
    /// One request as the fake saw it. `URLRequest.httpBody` is nil inside a URLProtocol, so the body
    /// is read from the body stream.
    struct Sent: Sendable {
        let method: String
        let url: URL
        let body: Data
        let headers: [String: String]

        var text: String { String(decoding: body, as: UTF8.self) }
        var json: JSONValue { JSONValue(parsing: body) ?? .null }
        /// The query as sent, percent-escapes intact.
        var query: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
        func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    }

    enum Reply: Sendable {
        /// The whole reply at once.
        case complete(status: Int, headers: [String: String], body: Data)
        /// The reply's start, then silence until the request is cancelled.
        case hang(status: Int, headers: [String: String], body: Data)
        /// The reply's start, then the connection breaks.
        case cut(status: Int, headers: [String: String], body: Data, error: URLError.Code)
        /// The reply in pieces, each after its own delay.
        case trickle(status: Int, headers: [String: String], pieces: [Piece])
        /// The request fails before any reply.
        case fail(URLError.Code)
    }

    struct Piece: Sendable {
        let delay: TimeInterval
        let data: Data
    }

    // MARK: State (one test at a time)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Sent) -> Reply)?
    nonisolated(unsafe) private static var recorded: [Sent] = []
    nonisolated(unsafe) private static var stopCount = 0

    static func reset(_ handler: (@Sendable (Sent) -> Reply)?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded = []
        stopCount = 0
    }

    static var requests: [Sent] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// How many requests were cancelled or finished (URLSession calls `stopLoading` for both).
    static var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBedrock.self]
        return URLSession(configuration: configuration)
    }

    // MARK: Replies

    static let eventStreamHeaders = ["Content-Type": "application/vnd.amazon.eventstream"]

    /// A 200 ConverseStream response carrying `frames`.
    static func reply(_ frames: [UInt8]...) -> Reply {
        .complete(status: 200, headers: eventStreamHeaders, body: Data(frames.joined()))
    }

    /// An AWS JSON error response: {"message"} with the type in x-amzn-ErrorType.
    static func error(_ status: Int, _ type: String, _ message: String, headers: [String: String] = [:]) -> Reply {
        let body = JSONValue.object(["message": .string(message)]).serialized()
        return .complete(status: status,
                         headers: ["Content-Type": "application/json", "x-amzn-ErrorType": type].merging(headers) { $1 },
                         body: Data(body.utf8))
    }

    static func json(_ text: String, status: Int = 200) -> Reply {
        .complete(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    /// "Tue, 29 Sep 2026 12:49:56 GMT".
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    // MARK: URLProtocol

    private let flag = BedrockTestBox(false)
    private var stopped: Bool { flag.current }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let sent = Sent(method: request.httpMethod ?? "GET", url: request.url!, body: body,
                        headers: request.allHTTPHeaderFields ?? [:])
        Self.lock.lock()
        Self.recorded.append(sent)
        let handler = Self.handler
        Self.lock.unlock()

        switch handler?(sent) ?? .fail(.cannotConnectToHost) {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .complete(let status, let headers, let data):
            begin(status, headers)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case .hang(let status, let headers, let data):
            begin(status, headers)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        case .cut(let status, let headers, let data, let code):
            begin(status, headers)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .trickle(let status, let headers, let pieces):
            begin(status, headers)
            deliver(pieces[...])
        }
    }

    private func begin(_ status: Int, _ headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func deliver(_ pieces: ArraySlice<Piece>) {
        guard let piece = pieces.first else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + piece.delay) { [self] in
            guard !stopped else { return }
            client?.urlProtocol(self, didLoad: piece.data)
            deliver(pieces.dropFirst())
        }
    }

    override func stopLoading() {
        flag.update { $0 = true }
        Self.lock.lock(); Self.stopCount += 1; Self.lock.unlock()
    }
}

// MARK: - BedrockClient against the fake

/// BedrockClient against an in-memory Bedrock: real event-stream frames, AWS error replies, credential
/// refresh, API keys, endpoints, model listing, and the engine round trip of Claude's signed reasoning.
final class BedrockClientTests: XCTestCase {
    private static let sonnet45 = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
    private static let opus47 = "us.anthropic.claude-opus-4-7"
    private static let runtime = "https://bedrock-runtime.us-east-1.amazonaws.com"

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = FakeBedrock.makeSession()
        FakeBedrock.reset(nil)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        FakeBedrock.reset(nil)
        BedrockClient.idleTimeout = 600
        BedrockClient.listModelsTimeout = 20
        super.tearDown()
    }

    // MARK: Helpers

    private static func profile(_ model: String = sonnet45) -> ProviderProfile {
        ProviderProfile(kind: .bedrock, name: "Bedrock", baseURL: runtime, model: model,
                        awsProfile: "dsh-bedrock", awsRegion: "us-east-1")
    }

    private func client(_ profile: ProviderProfile? = nil,
                        source: (any AWSCredentialSource)? = StaticAWSCredentialSource(SigV4Tests.withToken)) -> BedrockClient {
        BedrockClient(profile: profile ?? Self.profile(), credentials: source, session: session, clock: { SigV4Tests.now })
    }

    private static func request(_ messages: [LLMMessage] = [.user("hi")]) -> LLMRequest {
        LLMRequest(systemPrompt: "You are DSH.", messages: messages, tools: [], model: "")
    }

    private struct Collected {
        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var finish: String?
        var usage: LLMUsage?
        var providerState: String?
    }

    private func collect(_ client: some LLMClient, _ request: LLMRequest? = nil,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> Collected {
        var result = Collected()
        var done = false
        for try await event in client.stream(request ?? Self.request()) {
            switch event {
            case .text(let delta): result.text += delta
            case .reasoning(let delta): result.reasoning += delta
            case .done(let calls, let finish, let usage, let state):
                result.calls = calls
                result.finish = finish
                result.usage = usage
                result.providerState = state
                done = true
            }
        }
        XCTAssertTrue(done, "a finished stream ends with .done", file: file, line: line)
        return result
    }

    /// The error a stream fails with, which must be an `LLMError`.
    private func failure(_ client: some LLMClient, _ request: LLMRequest? = nil,
                         file: StaticString = #filePath, line: UInt = #line) async -> LLMError? {
        do {
            _ = try await collect(client, request, file: file, line: line)
            XCTFail("the stream should have failed", file: file, line: line)
        } catch let error as LLMError {
            return error
        } catch {
            XCTFail("expected an LLMError, got \(error)", file: file, line: line)
        }
        return nil
    }

    private func retry(_ error: Error) -> String {
        switch RequestRetry.disposition(for: error) {
        case .fail: "fail"
        case .untilAvailable: "untilAvailable"
        case .limited: "limited"
        }
    }

    /// The HTTP status an error carries, as `LlmException.StatusCode` had it.
    private func status(_ error: LLMError) -> Int? {
        switch error {
        case .http(let code, _): code
        case .rejected(let status, _, _, _): status
        case .overflow: 400
        default: nil
        }
    }

    private func errorBody(_ error: LLMError) -> String? {
        switch error {
        case .http(_, let body): body
        case .rejected(_, _, let body, _): body
        case .overflow(_, let detail): detail
        default: nil
        }
    }

    private func isPermanent(_ error: LLMError) -> Bool {
        if case .rejected(_, _, _, let permanent) = error { return permanent }
        return false
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Hands out credentials in turn: the next set each time a refresh is forced.
    private final class RotatingSource: AWSCredentialSource, @unchecked Sendable {
        private let sets: [AWSCredentials]
        private let state = BedrockTestBox((index: 0, calls: [Bool]()))
        init(_ sets: AWSCredentials...) { self.sets = sets }

        var calls: [Bool] { state.current.calls }

        func credentials(forceRefresh: Bool) async throws -> AWSCredentials {
            state.update { state in
                state.calls.append(forceRefresh)
                if forceRefresh { state.index = min(state.index + 1, sets.count - 1) }
                return sets[state.index]
            }
        }
    }

    private struct SignedOutSource: AWSCredentialSource {
        func credentials(forceRefresh: Bool) async throws -> AWSCredentials {
            throw AWSSignInRequiredError(profile: "dsh-bedrock", message: "The SSO session has expired.")
        }
    }

    // MARK: Streaming

    func testStreamsTextAndReportsUsage() async throws {
        FakeBedrock.reset { _ in
            FakeBedrock.reply(EventStreamFrames.messageStart(), EventStreamFrames.textDelta(0, "Hel"),
                              EventStreamFrames.textDelta(0, "lo"), EventStreamFrames.blockStop(0), EventStreamFrames.stop("end_turn"),
                              EventStreamFrames.metadata(input: 10, output: 5, cacheRead: 100, cacheWrite: 3))
        }
        let result = try await collect(client())

        XCTAssertEqual(result.text, "Hello")
        XCTAssertTrue(result.calls.isEmpty)
        XCTAssertEqual(result.finish, "stop")
        // The whole prompt counts (10 + 100 cache-read + 3 cache-write), and the cache-read share is reported.
        XCTAssertEqual(result.usage, LLMUsage(promptTokens: 113, completionTokens: 5, cachedTokens: 100))
        XCTAssertNil(result.providerState)

        XCTAssertEqual(FakeBedrock.requests.count, 1)
        let sent = try XCTUnwrap(FakeBedrock.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.absoluteString, "\(Self.runtime)/model/us.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse-stream")
        XCTAssertTrue(sent.header("Authorization")?.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260929/us-east-1/bedrock/aws4_request, "
            + "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, Signature=") ?? false, "\(sent.headers)")
        XCTAssertEqual(sent.header("X-Amz-Date"), "20260929T123456Z")
        XCTAssertEqual(sent.header("X-Amz-Security-Token"), SigV4Tests.token)
        XCTAssertEqual(sent.header("Content-Type"), "application/json")
        XCTAssertEqual(sent.json["messages"]?[0]?["content"]?[0]?["text"]?.string, "hi")
    }

    func testTheSignatureCoversExactlyTheBodyThatWasSent() async throws {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.textDelta(0, "ok"), EventStreamFrames.stop("end_turn")) }
        _ = try await collect(client())
        let sent = try XCTUnwrap(FakeBedrock.requests.first)

        var again = URLRequest(url: sent.url)
        again.httpMethod = "POST"
        again.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try SigV4.sign(&again, body: sent.body, credentials: SigV4Tests.withToken, region: "us-east-1", service: "bedrock",
                       now: SigV4Tests.now)
        XCTAssertEqual(sent.header("Authorization"), again.value(forHTTPHeaderField: "Authorization"))

        var other = again
        try SigV4.sign(&other, body: sent.body + Data(" ".utf8), credentials: SigV4Tests.withToken, region: "us-east-1",
                       service: "bedrock", now: SigV4Tests.now)
        XCTAssertNotEqual(sent.header("Authorization"), other.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheRequestAsksForAnUncompressedStreamAndSaysWhoItIs() async throws {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.stop("end_turn")) }
        _ = try await collect(client())
        let sent = try XCTUnwrap(FakeBedrock.requests.first)
        XCTAssertEqual(sent.header("Accept-Encoding"), "identity")
        XCTAssertTrue(sent.header("User-Agent")?.hasPrefix("DSH-Mac/") ?? false, "\(sent.headers)")
    }

    func testProfileHeadersAreSentAndTheAmzOnesSigned() async throws {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.stop("end_turn")) }
        var profile = Self.profile()
        profile.customHeaders = ["X-Amz-Custom": "yes", "X-Trace": "abc", " ": "blank name is skipped", "User-Agent": "mine/1"]
        _ = try await collect(client(profile))
        let sent = try XCTUnwrap(FakeBedrock.requests.first)
        XCTAssertEqual(sent.header("X-Trace"), "abc")
        XCTAssertEqual(sent.header("X-Amz-Custom"), "yes")
        XCTAssertEqual(sent.header("User-Agent"), "mine/1", "a custom header replaces ours")
        XCTAssertFalse(sent.headers.keys.contains(" "))
        let authorization = try XCTUnwrap(sent.header("Authorization"))
        XCTAssertTrue(authorization.contains("SignedHeaders=content-type;host;x-amz-custom;x-amz-date;x-amz-security-token"), authorization)
    }

    func testTheRequestsModelBeatsTheProfilesAndAnArnIsOneEncodedSegment() async throws {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.stop("end_turn")) }
        let arn = "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0"
        let request = LLMRequest(systemPrompt: "s", messages: [.user("hi")], tools: [], model: arn)
        _ = try await collect(client(), request)
        let sent = try XCTUnwrap(FakeBedrock.requests.first)
        XCTAssertEqual(sent.url.absoluteString,
                       "\(Self.runtime)/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A123456789012%3Ainference-profile%2Fus.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse-stream")
        // The ARN names Claude, so its request has Claude's cache points.
        XCTAssertNotNil(sent.json["system"]?.array?.last?["cachePoint"])
    }

    func testAnEmptyModelIsAnError() async {
        let profile = Self.profile("")
        guard let error = await failure(client(profile)) else { return }
        guard case .noModel = error else { return XCTFail("\(error)") }
        XCTAssertTrue(FakeBedrock.requests.isEmpty)
    }

    func testToolInputSplitAcrossDeltasIsAssembled() async throws {
        FakeBedrock.reset { _ in
            FakeBedrock.reply(EventStreamFrames.messageStart(), EventStreamFrames.textDelta(0, "On it."),
                              EventStreamFrames.toolStart(1, id: "tooluse_abc", name: "echo"),
                              EventStreamFrames.toolInput(1, #"{"te"#), EventStreamFrames.toolInput(1, #"xt":"hi"}"#), EventStreamFrames.blockStop(1),
                              EventStreamFrames.toolStart(2, id: "tooluse_def", name: "list"), EventStreamFrames.blockStop(2),
                              EventStreamFrames.stop("tool_use"), EventStreamFrames.metadata(input: 1, output: 1))
        }
        let result = try await collect(client())

        XCTAssertEqual(result.text, "On it.")
        XCTAssertEqual(result.finish, "tool_calls")
        XCTAssertEqual(result.calls, [ToolCall(id: "tooluse_abc", name: "echo", arguments: #"{"text":"hi"}"#),
                                      ToolCall(id: "tooluse_def", name: "list", arguments: "{}")])
        XCTAssertNil(result.providerState, "nothing signed to send back")
    }

    func testReasoningStreamsAndItsSignedBlocksBecomeProviderState() async throws {
        FakeBedrock.reset { _ in
            FakeBedrock.reply(EventStreamFrames.messageStart(), EventStreamFrames.reasoning(0, text: "Let me "),
                              EventStreamFrames.reasoning(0, text: "think."), EventStreamFrames.reasoning(0, signature: "sig=="),
                              EventStreamFrames.blockStop(0), EventStreamFrames.reasoning(1, redacted: "AQID"),
                              EventStreamFrames.textDelta(2, "Calling."),
                              EventStreamFrames.toolStart(3, id: "tooluse_1", name: "echo"),
                              EventStreamFrames.toolInput(3, #"{"text":"x"}"#),
                              EventStreamFrames.stop("tool_use"), EventStreamFrames.metadata(input: 1, output: 1))
        }
        let result = try await collect(client(Self.profile(Self.opus47)))

        XCTAssertEqual(result.reasoning, "Let me think.")
        XCTAssertEqual(result.text, "Calling.")
        let state = try XCTUnwrap(result.providerState)
        XCTAssertEqual(JSONValue(parsing: state), JSONValue(parsing: """
            [{"reasoningContent":{"reasoningText":{"text":"Let me think.","signature":"sig=="}}},
             {"reasoningContent":{"redactedContent":"AQID"}},{"text":"Calling."},
             {"toolUse":{"toolUseId":"tooluse_1","name":"echo","input":{"text":"x"}}}]
            """))
    }

    func testStopReasonsMapToFinishWords() async throws {
        for (reason, finish) in [("max_tokens", "length"), ("stop_sequence", "stop"), ("end_turn", "stop"), ("tool_use", "tool_calls"),
                                 ("guardrail_intervened", "guardrail_intervened"), ("content_filtered", "content_filtered")] {
            FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.textDelta(0, "x"), EventStreamFrames.stop(reason)) }
            let result = try await collect(client())
            XCTAssertEqual(result.finish, finish, reason)
        }
    }

    func testContextWindowExceededIsAnOverflow() async {
        FakeBedrock.reset { _ in
            FakeBedrock.reply(EventStreamFrames.textDelta(0, "partial"), EventStreamFrames.stop("model_context_window_exceeded"))
        }
        guard let error = await failure(client()) else { return }
        guard case .overflow = error else { return XCTFail("\(error)") }
    }

    func testStreamWithoutMessageStopWasCutOff() async {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.messageStart(), EventStreamFrames.textDelta(0, "Hel")) }
        guard let error = await failure(client()) else { return }
        guard case .sse(let why) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(why, "the reply was cut off before it finished")
        XCTAssertEqual(retry(error), "untilAvailable")
    }

    func testAnEmptyStreamIsACutConnectionToo() async {
        FakeBedrock.reset { _ in FakeBedrock.reply() }
        guard let error = await failure(client()) else { return }
        guard case .sse(let why) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(why, "the server closed the connection without replying")
        XCTAssertEqual(retry(error), "untilAvailable")
    }

    func testCorruptFrameIsARetryableStreamError() async {
        var frame = EventStreamFrames.textDelta(0, "Hello")
        frame[frame.count - 6] ^= 0x20
        let bad = frame
        FakeBedrock.reset { _ in FakeBedrock.reply(bad) }
        guard let error = await failure(client()) else { return }
        guard case .sse(let why) = error else { return XCTFail("\(error)") }
        XCTAssertTrue(why.contains("checksum"), why)
        XCTAssertEqual(retry(error), "untilAvailable")
    }

    func testAStreamCutInsideAFrameIsAStreamError() async {
        let frame = EventStreamFrames.textDelta(0, "Hello")
        let cut = Array(frame.prefix(frame.count - 3))
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.messageStart(), cut) }
        guard let error = await failure(client()) else { return }
        guard case .sse(let why) = error else { return XCTFail("\(error)") }
        XCTAssertTrue(why.contains("inside a frame"), why)
    }

    func testTheConnectionBreakingMidStreamIsAStreamError() async {
        FakeBedrock.reset { _ in
            .cut(status: 200, headers: FakeBedrock.eventStreamHeaders,
                 body: Data(EventStreamFrames.messageStart() + EventStreamFrames.textDelta(0, "par")), error: .networkConnectionLost)
        }
        guard let error = await failure(client()) else { return }
        guard case .sse = error else { return XCTFail("\(error)") }
        XCTAssertEqual(retry(error), "untilAvailable")
    }

    func testExceptionFramesMapLikeHttpErrors() async {
        let cases: [(String, String, Int, String)] = [
            ("throttlingException", "Too many tokens, please wait.", 429, "untilAvailable"),
            ("serviceUnavailableException", "Bedrock is unable to process your request.", 503, "untilAvailable"),
            ("internalServerException", "Internal error", 500, "limited"),
            ("modelStreamErrorException", "The model stream failed.", 500, "limited"),
            ("validationException", "The format of the value at messages.3 is invalid.", 400, "fail"),
        ]
        for (type, message, code, disposition) in cases {
            FakeBedrock.reset { _ in
                FakeBedrock.reply(EventStreamFrames.messageStart(), EventStreamFrames.textDelta(0, "par"),
                                  EventStreamFrames.exception(type, message))
            }
            guard let error = await failure(client()) else { return }
            XCTAssertEqual(status(error), code, type)
            XCTAssertEqual(retry(error), disposition, type)
            XCTAssertTrue(error.localizedDescription.contains(message), "\(type): \(error.localizedDescription)")
            if case .overflow = error { XCTFail("\(type) is not an overflow") }
        }
    }

    func testUnmodelledErrorFramesAreMappedToo() async {
        let frame = EventStreamFrames.frame([(":error-code", "InternalFailure"), (":error-message", "It broke."),
                                             (":message-type", "error")], payload: Data())
        FakeBedrock.reset { _ in FakeBedrock.reply(frame) }
        guard let error = await failure(client()) else { return }
        XCTAssertEqual(status(error), 500)
        XCTAssertTrue(error.localizedDescription.contains("It broke."), error.localizedDescription)
        XCTAssertEqual(retry(error), "limited")
    }

    func testFramesOfOtherTypesAndUnreadablePayloadsAreSkipped() async throws {
        let unknown = EventStreamFrames.frame([(":message-type", "keepalive")], payload: Data("x".utf8))
        let garbage = EventStreamFrames.frame([(":event-type", "contentBlockDelta"), (":message-type", "event")],
                                              payload: Data("not json".utf8))
        FakeBedrock.reset { _ in
            FakeBedrock.reply(unknown, garbage, EventStreamFrames.textDelta(0, "ok"), EventStreamFrames.event("somethingNew", ["a": 1]),
                              EventStreamFrames.stop("end_turn"))
        }
        let result = try await collect(client())
        XCTAssertEqual(result.text, "ok")
    }

    func testOverflowInAnExceptionFrameCarriesTheLimit() async {
        FakeBedrock.reset { _ in
            FakeBedrock.reply(EventStreamFrames.exception("validationException", "prompt is too long: 250000 tokens > 200000 maximum"))
        }
        guard let error = await failure(client()) else { return }
        guard case .overflow(let limit, _) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(limit, 200_000)
    }

    func testNonEventStreamReplyIsNotRetried() async {
        FakeBedrock.reset { _ in FakeBedrock.json(#"{"hello":"proxy"}"#) }
        guard let error = await failure(client()) else { return }
        guard case .http(let code, let message) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(code, 200)
        XCTAssertTrue(message.contains("unrecognised reply"), message)
        XCTAssertTrue(error.localizedDescription.contains("unrecognised reply"))
        XCTAssertEqual(retry(error), "fail")
    }

    func testConnectionFailureIsAConnectionError() async {
        FakeBedrock.reset { _ in .fail(.cannotConnectToHost) }
        guard let error = await failure(client()) else { return }
        guard case .connection = error else { return XCTFail("\(error)") }
        XCTAssertEqual(retry(error), "untilAvailable")
        XCTAssertEqual(FakeBedrock.requests.count, 1)
    }

    func testACertificateProblemSurfacesAtOnceInsteadOfBeingRetriedForEver() async {
        // A proxy that inspects TLS, say: nothing that waiting fixes.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .badURL] {
            FakeBedrock.reset { _ in .fail(code) }
            guard let error = await failure(client()) else { return }
            guard case .rejected(_, let message, _, let permanent) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(permanent, "\(code)")
            XCTAssertTrue(message.hasPrefix("Could not reach Amazon Bedrock"), message)
            XCTAssertEqual(retry(error), "fail", "\(code)")
            XCTAssertEqual(FakeBedrock.requests.count, 1)
        }
    }

    func testATimedOutRequestIsAConnectionErrorToo() async {
        FakeBedrock.reset { _ in .fail(.timedOut) }
        guard let error = await failure(client()) else { return }
        guard case .connection(let why) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(why, "the request timed out")
    }

    func testCancellationStopsTheStream() async throws {
        let first = Data(EventStreamFrames.messageStart() + EventStreamFrames.textDelta(0, "first"))
        FakeBedrock.reset { _ in .hang(status: 200, headers: FakeBedrock.eventStreamHeaders, body: first) }
        let stream = client().stream(Self.request())
        let seen = BedrockTestBox<[String]>([])
        let sawDone = BedrockTestBox(false)
        let task = Task {
            for try await event in stream {
                switch event {
                case .text(let delta): seen.update { $0.append(delta) }
                case .done: sawDone.update { $0 = true }
                case .reasoning: break
                }
            }
        }
        try await waitUntil("the first text") { seen.current == ["first"] }
        task.cancel()
        let outcome = await task.result
        if case .failure(let error) = outcome { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(seen.current, ["first"])
        XCTAssertFalse(sawDone.current, "a cancelled stream does not pass as a finished one")
        // Cancelling must end the HTTP request too, or the model keeps generating for nobody.
        try await waitUntil("the request to be cancelled") { FakeBedrock.stops >= 1 }
    }

    func testAStreamThatGoesQuietIsADeadStream() async throws {
        BedrockClient.idleTimeout = 0.3
        let first = Data(EventStreamFrames.messageStart() + EventStreamFrames.textDelta(0, "first"))
        FakeBedrock.reset { _ in .hang(status: 200, headers: FakeBedrock.eventStreamHeaders, body: first) }
        let started = Date()
        guard let error = await failure(client()) else { return }
        guard case .sse(let why) = error else { return XCTFail("\(error)") }
        XCTAssertTrue(why.hasPrefix("no data from Bedrock for "), why)
        XCTAssertEqual(retry(error), "untilAvailable")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "the watchdog fired at the idle limit, not at some later timeout")
        try await waitUntil("the request to be cancelled") { FakeBedrock.stops >= 1 }
    }

    func testTheIdleLimitIsReportedInWholeSeconds() async {
        BedrockClient.idleTimeout = 1.2
        FakeBedrock.reset { _ in .hang(status: 200, headers: FakeBedrock.eventStreamHeaders, body: Data(EventStreamFrames.messageStart())) }
        guard let error = await failure(client()) else { return }
        guard case .sse(let why) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(why, "no data from Bedrock for 1 s")
    }

    func testAStreamThatKeepsTalkingIsNotIdle() async throws {
        BedrockClient.idleTimeout = 1.0
        // Ten frames a quarter of a second apart: longer than the idle limit in all, never silent for it.
        var pieces = [FakeBedrock.Piece(delay: 0.05, data: Data(EventStreamFrames.messageStart()))]
        for word in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            pieces.append(FakeBedrock.Piece(delay: 0.25, data: Data(EventStreamFrames.textDelta(0, word))))
        }
        pieces.append(FakeBedrock.Piece(delay: 0.25, data: Data(EventStreamFrames.stop("end_turn"))))
        let all = pieces
        FakeBedrock.reset { _ in .trickle(status: 200, headers: FakeBedrock.eventStreamHeaders, pieces: all) }
        let started = Date()
        let result = try await collect(client())
        XCTAssertEqual(result.text, "abcdefgh")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.0, "the reply outlasted the idle limit")
    }

    func testAnEventSplitAcrossTheNetworkInManyPiecesIsStillOneEvent() async throws {
        let whole = EventStreamFrames.messageStart() + EventStreamFrames.textDelta(0, "héllo — ✓") + EventStreamFrames.stop("end_turn")
        let pieces = stride(from: 0, to: whole.count, by: 7).map { start in
            FakeBedrock.Piece(delay: 0.001, data: Data(whole[start..<min(start + 7, whole.count)]))
        }
        FakeBedrock.reset { _ in .trickle(status: 200, headers: FakeBedrock.eventStreamHeaders, pieces: pieces) }
        let result = try await collect(client())
        XCTAssertEqual(result.text, "héllo — ✓")
    }

    // MARK: HTTP errors

    func testHttpErrorsMapToTheRightRetryClass() async {
        // status, x-amzn-ErrorType, message, error kind, status of the error, retry class
        let cases: [(Int, String, String, String, Int, String)] = [
            (400, "ValidationException:http://internal.amazon.com/coral/com.amazon.bedrock/", "Input is too long for requested model.", "overflow", 400, "fail"),
            (400, "ValidationException", "input length and `max_tokens` exceed context limit: 180000 + 32000 > 200000", "overflow", 400, "fail"),
            (400, "ValidationException", "The maximum tokens you requested exceeds the model limit of 8192.", "http", 400, "fail"),
            (403, "AccessDeniedException", "You don't have access to the model with the specified model ID.", "http", 403, "fail"),
            (404, "ResourceNotFoundException", "Model not found.", "http", 404, "fail"),
            (429, "ThrottlingException", "Too many requests, please wait before trying again.", "http", 429, "untilAvailable"),
            (429, "ServiceQuotaExceededException", "Your request exceeds the service quota for your account.", "http", 429, "untilAvailable"),
            (429, "ModelNotReadyException", "Model is not ready for inference.", "http", 429, "untilAvailable"),
            (503, "ServiceUnavailableException", "Service unavailable.", "http", 503, "untilAvailable"),
            (500, "InternalServerException", "Internal server error.", "http", 500, "limited"),
            (424, "ModelErrorException", "The model failed.", "http", 500, "limited"),
            (408, "ModelTimeoutException", "The model timed out.", "http", 408, "untilAvailable"),
        ]
        for (code, type, message, kind, expectedCode, disposition) in cases {
            FakeBedrock.reset { _ in FakeBedrock.error(code, type, message) }
            guard let error = await failure(client()) else { return }
            let isOverflow: Bool
            if case .overflow = error { isOverflow = true } else { isOverflow = false }
            XCTAssertEqual(isOverflow ? "overflow" : "http", kind, "\(code) \(type)")
            XCTAssertEqual(status(error), expectedCode, "\(code) \(type)")
            XCTAssertEqual(retry(error), disposition, "\(code) \(type)")
            XCTAssertTrue(error.localizedDescription.contains(message), "\(type): \(error.localizedDescription)")
            XCTAssertEqual(FakeBedrock.requests.count, 1, "\(code) \(type) is not sent twice")
        }
    }

    func testTheContextLimitAnOverflowNamesIsCarried() async {
        FakeBedrock.reset { _ in
            FakeBedrock.error(400, "ValidationException", "input length and `max_tokens` exceed context limit: 180000 + 32000 > 200000")
        }
        guard let error = await failure(client()) else { return }
        guard case .overflow(let limit, _) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(limit, 200_000)
        FakeBedrock.reset { _ in FakeBedrock.error(400, "ValidationException", "Input is too long for requested model.") }
        guard let unknown = await failure(client()), case .overflow(let none, _) = unknown else { return XCTFail("expected an overflow") }
        XCTAssertEqual(none, 0)
    }

    func testAccessDeniedNamesTheModelAndTheSubscriptionDelay() async {
        FakeBedrock.reset { _ in
            FakeBedrock.error(403, "AccessDeniedException",
                              "Model access is denied due to IAM user or service role is not authorized to perform the required AWS Marketplace actions (aws-marketplace:ViewSubscriptions, aws-marketplace:Subscribe).")
        }
        guard let error = await failure(client()) else { return }
        let message = error.localizedDescription
        XCTAssertTrue(message.contains(Self.sonnet45), message)
        XCTAssertTrue(message.contains("us-east-1"), message)
        XCTAssertTrue(message.contains("Settings ▸ Models"), message)
        XCTAssertTrue(message.contains("15 minutes"), message)
    }

    func testPlainAccessDeniedDoesNotPromiseAFifteenMinuteWait() async {
        FakeBedrock.reset { _ in FakeBedrock.error(403, "AccessDeniedException", "You don't have access to the model.") }
        guard let error = await failure(client()) else { return }
        XCTAssertFalse(error.localizedDescription.contains("15 minutes"))
        XCTAssertFalse(isPermanent(error))
    }

    func testAModelThatIsNotFoundIsNotWaitedFor() async {
        FakeBedrock.reset { _ in FakeBedrock.error(404, "ResourceNotFoundException", "Could not resolve the foundation model.") }
        guard let error = await failure(client()) else { return }
        XCTAssertTrue(isPermanent(error))
        XCTAssertTrue(error.localizedDescription.contains("inference profile"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains(Self.sonnet45), error.localizedDescription)
        XCTAssertEqual(retry(error), "fail")
    }

    func testMessageIsReadFromACapitalisedFieldToo() async {
        FakeBedrock.reset { _ in
            .complete(status: 400, headers: ["Content-Type": "application/json", "x-amzn-ErrorType": "ValidationException"],
                      body: Data(#"{"Message":"Malformed input request"}"#.utf8))
        }
        guard let error = await failure(client()) else { return }
        XCTAssertTrue(error.localizedDescription.contains("Malformed input request"), error.localizedDescription)
        XCTAssertEqual(errorBody(error), "ValidationException: Malformed input request")
    }

    func testTheErrorTypeCanComeFromTheBodyWhenThereIsNoHeader() async {
        FakeBedrock.reset { _ in
            FakeBedrock.json(#"{"__type":"com.amazon.coral.availability#ThrottlingException","message":"Slow down."}"#, status: 400)
        }
        guard let error = await failure(client()) else { return }
        XCTAssertEqual(status(error), 429)
        XCTAssertEqual(retry(error), "untilAvailable")
        XCTAssertEqual(errorBody(error), "com.amazon.coral.availability#ThrottlingException: Slow down.")
    }

    func testAnErrorWithNoJsonBodyKeepsItsText() async {
        FakeBedrock.reset { _ in .complete(status: 502, headers: ["Content-Type": "text/html"], body: Data("<html>Bad gateway</html>".utf8)) }
        guard let error = await failure(client()) else { return }
        guard case .http(let code, let body) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(code, 502)
        XCTAssertEqual(body, "<html>Bad gateway</html>")
        XCTAssertEqual(retry(error), "untilAvailable")
    }

    func testAnErrorBodyIsReadOnlyToItsFirst8KB() async {
        let big = String(repeating: "x", count: 50_000)
        FakeBedrock.reset { _ in .complete(status: 502, headers: [:], body: Data(big.utf8)) }
        guard let error = await failure(client()) else { return }
        guard case .http(_, let body) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(body.count, 8_000)
    }

    func testRequestTooLargeIsTreatedAsAnOverflow() async {
        FakeBedrock.reset { _ in .complete(status: 413, headers: [:], body: Data()) }
        guard let error = await failure(client()) else { return }
        guard case .overflow(let limit, _) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(limit, 0)
    }

    func testAnUnknownAwsErrorIsAPlainHttpError() async {
        FakeBedrock.reset { _ in FakeBedrock.error(418, "TeapotException", "I am a teapot.") }
        guard let error = await failure(client()) else { return }
        guard case .http(let code, let body) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(code, 418)
        XCTAssertEqual(body, "TeapotException: I am a teapot.")
    }

    // MARK: Credentials

    func testExpiredCredentialsAreRefreshedOnceAndTheRequestResent() async throws {
        let source = RotatingSource(AWSCredentials(accessKeyID: "OLDKEY", secretAccessKey: "old", sessionToken: "old-token"),
                                    SigV4Tests.withToken)
        let count = BedrockTestCounter()
        FakeBedrock.reset { _ in
            count.next() == 1
                ? FakeBedrock.error(403, "ExpiredTokenException", "The security token included in the request is expired")
                : FakeBedrock.reply(EventStreamFrames.textDelta(0, "fresh"), EventStreamFrames.stop("end_turn"))
        }
        let result = try await collect(client(source: source))

        XCTAssertEqual(result.text, "fresh")
        XCTAssertEqual(source.calls, [false, true])
        let requests = FakeBedrock.requests
        guard requests.count == 2 else { return XCTFail("expected two requests, got \(requests.count)") }
        XCTAssertTrue(requests[0].header("Authorization")?.contains("Credential=OLDKEY/") ?? false)
        XCTAssertTrue(requests[1].header("Authorization")?.contains("Credential=AKIDEXAMPLE/") ?? false)
        XCTAssertEqual(requests[0].body, requests[1].body, "the same request is sent again")
    }

    func testCredentialsStillRejectedAfterARefreshSurfacePermanently() async {
        let source = RotatingSource(SigV4Tests.withToken)
        FakeBedrock.reset { _ in
            FakeBedrock.error(403, "UnrecognizedClientException", "The security token included in the request is invalid.")
        }
        guard let error = await failure(client(source: source)) else { return }
        XCTAssertEqual(FakeBedrock.requests.count, 2)
        XCTAssertEqual(retry(error), "fail")
        XCTAssertTrue(isPermanent(error))
        XCTAssertTrue(error.localizedDescription.contains("aws login --profile dsh-bedrock"), error.localizedDescription)
        XCTAssertEqual(source.calls, [false, true])
    }

    func testClockSkewIsCorrectedFromAwsTime() async throws {
        let count = BedrockTestCounter()
        FakeBedrock.reset { _ in
            if count.next() > 1 { return FakeBedrock.reply(EventStreamFrames.textDelta(0, "ok"), EventStreamFrames.stop("end_turn")) }
            return FakeBedrock.error(403, "InvalidSignatureException",
                                     "Signature expired: 20260929T123456Z is now earlier than 20260929T124456Z (20260929T124956Z - 5 min.)",
                                     headers: ["Date": FakeBedrock.httpDate(SigV4Tests.now.addingTimeInterval(15 * 60))])
        }
        let result = try await collect(client())
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(FakeBedrock.requests.map { $0.header("X-Amz-Date") }, ["20260929T123456Z", "20260929T124956Z"])
    }

    func testTheLearnedSkewCarriesToTheNextRequestOfTheSameClient() async throws {
        let count = BedrockTestCounter()
        FakeBedrock.reset { _ in
            let n = count.next()
            if n == 1 {
                return FakeBedrock.error(403, "RequestTimeTooSkewed", "The difference between the request time and the current time is too large.",
                                         headers: ["Date": FakeBedrock.httpDate(SigV4Tests.now.addingTimeInterval(-3600))])
            }
            return FakeBedrock.reply(EventStreamFrames.textDelta(0, "ok"), EventStreamFrames.stop("end_turn"))
        }
        let c = client()
        _ = try await collect(c)
        _ = try await collect(c)
        let dates = FakeBedrock.requests.map { $0.header("X-Amz-Date") }
        XCTAssertEqual(dates, ["20260929T123456Z", "20260929T113456Z", "20260929T113456Z"])
    }

    func testSkewWithoutADateHeaderIsAnAuthenticationError() async {
        FakeBedrock.reset { _ in FakeBedrock.error(403, "InvalidSignatureException", "Signature expired: 20260929T123456Z is now earlier than 20260929T124456Z") }
        guard let error = await failure(client()) else { return }
        XCTAssertEqual(FakeBedrock.requests.count, 1)
        XCTAssertTrue(isPermanent(error))
        XCTAssertEqual(retry(error), "fail")
    }

    func testOnlyOneRetryIsSpentOnCredentialsAndClockTogether() async {
        let count = BedrockTestCounter()
        FakeBedrock.reset { _ in
            count.next() == 1
                ? FakeBedrock.error(403, "ExpiredTokenException", "The security token included in the request is expired")
                : FakeBedrock.error(403, "InvalidSignatureException", "Signature expired: x",
                                    headers: ["Date": FakeBedrock.httpDate(SigV4Tests.now)])
        }
        guard let error = await failure(client()) else { return }
        XCTAssertEqual(FakeBedrock.requests.count, 2)
        XCTAssertTrue(isPermanent(error))
    }

    func testSignInRequiredIsAPermanentErrorThatSaysHowToSignIn() async {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.stop("end_turn")) }
        guard let error = await failure(client(source: SignedOutSource())) else { return }

        XCTAssertEqual(retry(error), "fail")
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("expired"), message)
        XCTAssertTrue(message.contains("Settings ▸ Models"), message)
        XCTAssertTrue(message.contains("aws login --profile dsh-bedrock"), message)
        XCTAssertEqual(status(error), 401)
        XCTAssertTrue(isPermanent(error))
        XCTAssertEqual(errorBody(error), "The SSO session has expired.")
        XCTAssertTrue(FakeBedrock.requests.isEmpty)
    }

    func testTheHostCanTellWhichProfileNeedsSigningIn() async {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.stop("end_turn")) }
        guard let error = await failure(client(source: SignedOutSource())) else { return }
        XCTAssertEqual(BedrockClient.expiredSignInProfile(in: error), "dsh-bedrock")

        // Other permanent refusals, and other errors altogether, are not a sign-in prompt.
        FakeBedrock.reset { _ in FakeBedrock.error(403, "UnrecognizedClientException", "The security token included in the request is invalid.") }
        guard let rejected = await failure(client()) else { return }
        XCTAssertNil(BedrockClient.expiredSignInProfile(in: rejected))
        XCTAssertNil(BedrockClient.expiredSignInProfile(in: LLMError.connection("down")))
        XCTAssertNil(BedrockClient.expiredSignInProfile(in: CancellationError()))
        XCTAssertNil(BedrockClient.expiredSignInProfile(in: LLMError.rejected(
            status: 401, message: "The AWS sign-in for profile \"p\" has expired.", body: "", permanent: false)))
        XCTAssertEqual(BedrockClient.expiredSignInProfile(in: LLMError.rejected(
            status: 401, message: "The AWS sign-in for profile \"my \"quoted\" one\" has expired. Sign in again", body: "", permanent: true)),
                       "my \"quoted\" one")
    }

    func testOtherCredentialFailuresPropagateUntouched() async {
        struct Boom: Error, Equatable {}
        struct BrokenSource: AWSCredentialSource {
            func credentials(forceRefresh: Bool) async throws -> AWSCredentials { throw Boom() }
        }
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.stop("end_turn")) }
        do {
            _ = try await collect(client(source: BrokenSource()))
            XCTFail("expected the credential error")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
        XCTAssertTrue(FakeBedrock.requests.isEmpty)
    }

    func testNoCredentialSourceAsksForASignIn() async {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.stop("end_turn")) }
        guard let error = await failure(client(source: nil)) else { return }
        XCTAssertEqual(retry(error), "fail")
        XCTAssertTrue(error.localizedDescription.contains("sign-in"), error.localizedDescription)
        XCTAssertTrue(FakeBedrock.requests.isEmpty)
    }

    func testApiKeyIsSentAsABearerToken() async throws {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.textDelta(0, "ok"), EventStreamFrames.stop("end_turn")) }
        var profile = Self.profile()
        profile.awsProfile = nil
        profile.apiKey = "bedrock-api-key-abc"
        let keyed = client(profile, source: nil)
        XCTAssertTrue(keyed.usesAPIKey)
        _ = try await collect(keyed)

        XCTAssertEqual(FakeBedrock.requests.count, 1)
        let sent = try XCTUnwrap(FakeBedrock.requests.first)
        XCTAssertEqual(sent.header("Authorization"), "Bearer bedrock-api-key-abc")
        XCTAssertNil(sent.header("X-Amz-Date"))
    }

    func testAnAwsProfileWinsOverAnApiKeyLeftOnTheRoute() {
        var profile = Self.profile()
        profile.apiKey = "bedrock-api-key-old"
        XCTAssertFalse(client(profile).usesAPIKey)
        profile.awsProfile = nil
        XCTAssertTrue(client(profile).usesAPIKey)
        profile.apiKey = ""
        XCTAssertFalse(client(profile).usesAPIKey)
        profile.apiKey = nil
        XCTAssertFalse(client(profile).usesAPIKey)
    }

    func testRejectedApiKeyIsPermanent() async {
        FakeBedrock.reset { _ in FakeBedrock.error(403, "AccessDeniedException", "Authentication failed: Please make sure your API Key is valid.") }
        var profile = Self.profile()
        profile.awsProfile = nil
        profile.apiKey = "bedrock-api-key-old"
        guard let error = await failure(client(profile, source: nil)) else { return }
        XCTAssertTrue(error.localizedDescription.contains("API key"), error.localizedDescription)
        XCTAssertEqual(retry(error), "fail")
        XCTAssertEqual(FakeBedrock.requests.count, 1)
    }

    func testAnApiKeyRouteDoesNotRefreshAwsCredentials() async {
        let source = RotatingSource(SigV4Tests.withToken)
        FakeBedrock.reset { _ in FakeBedrock.error(403, "ExpiredTokenException", "The security token included in the request is expired") }
        var profile = Self.profile()
        profile.awsProfile = nil
        profile.apiKey = "bedrock-api-key-x"
        guard let error = await failure(client(profile, source: source)) else { return }
        XCTAssertEqual(FakeBedrock.requests.count, 1)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertTrue(error.localizedDescription.contains("API key"), error.localizedDescription)
    }

    func testAPlainAccessDeniedIsNotBlamedOnTheApiKey() async {
        FakeBedrock.reset { _ in FakeBedrock.error(403, "AccessDeniedException", "You don't have access to the model.") }
        var profile = Self.profile()
        profile.awsProfile = nil
        profile.apiKey = "bedrock-api-key-x"
        guard let error = await failure(client(profile, source: nil)) else { return }
        XCTAssertFalse(error.localizedDescription.contains("API key"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("refused access"), error.localizedDescription)
    }

    // MARK: Endpoints

    func testEndpointOverrideIsUsedAndSignedForTheProfileRegion() async throws {
        FakeBedrock.reset { _ in FakeBedrock.reply(EventStreamFrames.textDelta(0, "ok"), EventStreamFrames.stop("end_turn")) }
        var profile = Self.profile()
        profile.baseURL = "https://vpce-0abc.bedrock-runtime.us-west-2.vpce.amazonaws.com/"
        profile.awsRegion = "us-west-2"
        _ = try await collect(client(profile))

        let sent = try XCTUnwrap(FakeBedrock.requests.first)
        XCTAssertEqual(sent.url.host, "vpce-0abc.bedrock-runtime.us-west-2.vpce.amazonaws.com")
        XCTAssertTrue(sent.url.path.hasPrefix("/model/us.anthropic.claude-sonnet-4-5-20250929-v1:0/converse-stream"), sent.url.path)
        XCTAssertTrue(sent.url.absoluteString.contains("/model/us.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse-stream"))
        XCTAssertTrue(sent.header("Authorization")?.contains("/us-west-2/bedrock/aws4_request") ?? false)
    }

    func testRegionAndControlPlaneFollowTheRuntimeUrl() throws {
        var profile = Self.profile()
        profile.awsRegion = nil
        profile.baseURL = "https://bedrock-runtime.eu-west-1.amazonaws.com"
        var c = client(profile)
        XCTAssertEqual(c.region, "eu-west-1")
        XCTAssertEqual(try c.runtimeBase, "https://bedrock-runtime.eu-west-1.amazonaws.com")
        XCTAssertEqual(try c.controlBase, "https://bedrock.eu-west-1.amazonaws.com")

        profile.baseURL = ""
        profile.awsRegion = "ap-northeast-1"
        c = client(profile)
        XCTAssertEqual(try c.runtimeBase, "https://bedrock-runtime.ap-northeast-1.amazonaws.com")
        XCTAssertEqual(try c.controlBase, "https://bedrock.ap-northeast-1.amazonaws.com")
        XCTAssertEqual(try c.converseStreamURL("arn:aws:bedrock:ap-northeast-1:1:inference-profile/apac.x").absoluteString,
                       "https://bedrock-runtime.ap-northeast-1.amazonaws.com/model/arn%3Aaws%3Abedrock%3Aap-northeast-1%3A1%3Ainference-profile%2Fapac.x/converse-stream")

        // A public endpoint left over from before the Region changed follows the Region.
        profile.baseURL = "https://bedrock-runtime.us-east-1.amazonaws.com"
        c = client(profile)
        XCTAssertEqual(try c.runtimeBase, "https://bedrock-runtime.ap-northeast-1.amazonaws.com")
    }

    func testEndpointVariantsAndTheRegionsTheyName() throws {
        func region(_ base: String, _ awsRegion: String?) -> String? {
            var profile = Self.profile()
            profile.baseURL = base
            profile.awsRegion = awsRegion
            return client(profile).region
        }
        XCTAssertEqual(region("https://bedrock-runtime-fips.us-gov-west-1.amazonaws.com", nil), "us-gov-west-1")
        XCTAssertEqual(region("https://bedrock.us-east-2.amazonaws.com", nil), "us-east-2")
        XCTAssertEqual(region("https://BEDROCK-RUNTIME.EU-CENTRAL-1.AMAZONAWS.COM", nil), "eu-central-1")
        XCTAssertEqual(region("https://vpce-0abc.bedrock-runtime.us-west-2.vpce.amazonaws.com", nil), nil, "not a standard host")
        XCTAssertEqual(region("https://proxy.example.com/bedrock", nil), nil)
        XCTAssertEqual(region("https://bedrock-runtime.eu-west-1.amazonaws.com", "  us-east-1 "), "us-east-1", "the configured Region wins, trimmed")
        XCTAssertEqual(region("", "   "), nil)

        var profile = Self.profile()
        profile.baseURL = "https://gateway.example.com/bedrock/"
        var c = client(profile)
        XCTAssertEqual(try c.runtimeBase, "https://gateway.example.com/bedrock", "a proxy is used as given, minus the trailing slash")
        XCTAssertEqual(try c.controlBase, "https://bedrock.us-east-1.amazonaws.com", "…and the control plane is the Region's")
        profile.baseURL = "http://bedrock-runtime.us-east-1.amazonaws.com:8443"
        c = client(profile)
        XCTAssertEqual(try c.runtimeBase, "http://bedrock-runtime.us-east-1.amazonaws.com:8443")
        XCTAssertEqual(try c.controlBase, "http://bedrock.us-east-1.amazonaws.com:8443", "scheme and port carry over")
        profile.baseURL = "not a url at all"
        c = client(profile)
        XCTAssertEqual(try c.runtimeBase, "https://bedrock-runtime.us-east-1.amazonaws.com", "an unusable URL falls back to the Region's endpoint")
    }

    func testMissingRegionIsAPermanentError() async {
        FakeBedrock.reset { _ in FakeBedrock.reply() }
        var profile = Self.profile()
        profile.awsRegion = nil
        profile.baseURL = ""
        guard let error = await failure(client(profile)) else { return }
        XCTAssertTrue(error.localizedDescription.contains("Region"), error.localizedDescription)
        XCTAssertEqual(retry(error), "fail")
        XCTAssertTrue(FakeBedrock.requests.isEmpty)
        XCTAssertThrowsError(try client(profile).runtimeBase)
        XCTAssertThrowsError(try client(profile).controlBase)
    }

    // MARK: Reasoning replay

    private static let signedState = #"[{"reasoningContent":{"reasoningText":{"text":"t","signature":"s"}}},{"toolUse":{"toolUseId":"tooluse_1","name":"echo","input":{}}}]"#

    private static func toolTurnRequest(_ state: String?) -> LLMRequest {
        var assistant = LLMMessage.assistant("", calls: [ToolCall(id: "tooluse_1", name: "echo", arguments: "{}")])
        assistant.providerState = state
        return LLMRequest(systemPrompt: "You are DSH.",
                          messages: [.user("go"), assistant, .toolResult(id: "tooluse_1", name: "echo", output: "ok")],
                          tools: [ToolSpec(name: "echo", description: "echo", parameters: "{}")],
                          model: opus47, thinking: .high)
    }

    func testRefusedReasoningIsDroppedAndTheRequestSentAgain() async throws {
        let count = BedrockTestCounter()
        FakeBedrock.reset { _ in
            count.next() == 1
                ? FakeBedrock.error(400, "ValidationException",
                                    "messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation.")
                : FakeBedrock.reply(EventStreamFrames.textDelta(0, "done"), EventStreamFrames.stop("end_turn"))
        }
        let result = try await collect(client(Self.profile(Self.opus47)), Self.toolTurnRequest(Self.signedState))

        XCTAssertEqual(result.text, "done")
        let requests = FakeBedrock.requests
        guard requests.count == 2 else { return XCTFail("expected two requests, got \(requests.count)") }
        XCTAssertTrue(requests[0].text.contains("reasoningContent"))
        XCTAssertFalse(requests[1].text.contains("reasoningContent"))
    }

    func testReasoningIsDroppedOnlyOnceAndOnlyWhenThereWasSome() async {
        let refusal = "Invalid `signature` in `thinking` block."
        FakeBedrock.reset { _ in FakeBedrock.error(400, "ValidationException", refusal) }
        guard let twice = await failure(client(Self.profile(Self.opus47)), Self.toolTurnRequest(Self.signedState)) else { return }
        XCTAssertEqual(FakeBedrock.requests.count, 2, "it is not retried a second time")
        XCTAssertEqual(status(twice), 400)

        FakeBedrock.reset { _ in FakeBedrock.error(400, "ValidationException", refusal) }
        guard let once = await failure(client(Self.profile(Self.opus47)), Self.toolTurnRequest(nil)) else { return }
        XCTAssertEqual(FakeBedrock.requests.count, 1, "no stored reasoning, nothing to drop")
        XCTAssertEqual(status(once), 400)

        FakeBedrock.reset { _ in FakeBedrock.error(400, "ValidationException", "The format of the value at messages.3 is invalid.") }
        guard await failure(client(Self.profile(Self.opus47)), Self.toolTurnRequest(Self.signedState)) != nil else { return }
        XCTAssertEqual(FakeBedrock.requests.count, 1, "an unrelated 400 is not retried")
    }

    func testEngineCarriesSignedReasoningIntoTheNextBedrockRequest() async throws {
        let count = BedrockTestCounter()
        FakeBedrock.reset { _ in
            count.next() == 1
                ? FakeBedrock.reply(EventStreamFrames.reasoning(0, text: "plan"), EventStreamFrames.reasoning(0, signature: "sig-1"),
                                    EventStreamFrames.toolStart(1, id: "tooluse_9", name: EchoTool.name),
                                    EventStreamFrames.toolInput(1, #"{"text":"ping"}"#), EventStreamFrames.stop("tool_use"))
                : FakeBedrock.reply(EventStreamFrames.textDelta(0, "all done"), EventStreamFrames.stop("end_turn"))
        }
        let scratch = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("dsh-bedrock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = Engine(client: client(Self.profile(Self.sonnet45)), registry: ToolRegistry(tools: [EchoTool()]),
                            systemPrompt: "system",
                            config: EngineConfig(maxIterations: 5, toolTimeout: 5, model: Self.sonnet45, thinking: .high, retry: .off),
                            workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                            permissionGate: { _, _, _ in true })
        let result = try await engine.run(messages: [], userText: "go", sink: { _ in })

        XCTAssertEqual(result.finalText, "all done")
        XCTAssertNotNil(result.messages.first { $0.role == .assistant }?.providerState, "the engine stored the state on the message")
        let requests = FakeBedrock.requests
        guard requests.count == 2 else { return XCTFail("expected two requests, got \(requests.count)") }
        let assistant = requests[1].json["messages"]?[1]?["content"]
        XCTAssertEqual(assistant?[0]?["reasoningContent"]?["reasoningText"]?["signature"]?.string, "sig-1")
        XCTAssertEqual(assistant?[1]?["toolUse"]?["toolUseId"]?.string, "tooluse_9")
        XCTAssertEqual(requests[1].json["additionalModelRequestFields"]?["thinking"]?["budget_tokens"]?.int, 16_000)
    }

    // MARK: Models

    func testListModelsReturnsOnDemandModelsThenEveryInferenceProfilePage() async throws {
        FakeBedrock.reset { sent in
            if sent.url.path == "/foundation-models" {
                return FakeBedrock.json("""
                    {"modelSummaries":[
                      {"modelId":"anthropic.claude-sonnet-4-5-20250929-v1:0","inferenceTypesSupported":["INFERENCE_PROFILE"],"responseStreamingSupported":true},
                      {"modelId":"amazon.nova-pro-v1:0","inferenceTypesSupported":["ON_DEMAND"],"responseStreamingSupported":true},
                      {"modelId":"amazon.titan-tg1-large","inferenceTypesSupported":["ON_DEMAND"],"responseStreamingSupported":false},
                      {"modelId":"meta.llama3-3-70b-instruct-v1:0","inferenceTypesSupported":["ON_DEMAND","PROVISIONED"]}]}
                    """)
            }
            if sent.url.path == "/inference-profiles" {
                return (sent.query ?? "").contains("nextToken=page%2F2%2B%3D%3D")
                    ? FakeBedrock.json(#"{"inferenceProfileSummaries":[{"inferenceProfileId":"us.amazon.nova-pro-v1:0","status":"ACTIVE"}]}"#)
                    : FakeBedrock.json(#"{"inferenceProfileSummaries":[{"inferenceProfileId":"us.anthropic.claude-sonnet-4-5-20250929-v1:0","status":"ACTIVE"}],"nextToken":"page/2+=="}"#)
            }
            return .complete(status: 404, headers: [:], body: Data())
        }
        let models = try await client().listModels()

        XCTAssertEqual(models, ["amazon.nova-pro-v1:0", "meta.llama3-3-70b-instruct-v1:0",
                                "us.anthropic.claude-sonnet-4-5-20250929-v1:0", "us.amazon.nova-pro-v1:0"])
        let requests = FakeBedrock.requests
        guard requests.count == 3 else { return XCTFail("expected three requests, got \(requests.count)") }
        for sent in requests {
            XCTAssertEqual(sent.url.host, "bedrock.us-east-1.amazonaws.com")
            XCTAssertEqual(sent.method, "GET")
            XCTAssertTrue(sent.header("Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260929/us-east-1/bedrock/aws4_request") ?? false)
            XCTAssertNil(sent.header("Content-Type"))
        }
        XCTAssertEqual(requests[0].query, "byOutputModality=TEXT")
        XCTAssertEqual(requests[1].query, "maxResults=1000")
        XCTAssertEqual(requests[2].query, "maxResults=1000&nextToken=page%2F2%2B%3D%3D")
    }

    func testListModelsSkipsInactiveProfilesAndDuplicates() async throws {
        FakeBedrock.reset { sent in
            sent.url.path == "/foundation-models"
                ? FakeBedrock.json(#"{"modelSummaries":[{"modelId":"amazon.nova-pro-v1:0","inferenceTypesSupported":["ON_DEMAND"]},{"modelId":"","inferenceTypesSupported":["ON_DEMAND"]},"junk"]}"#)
                : FakeBedrock.json(#"{"inferenceProfileSummaries":[{"inferenceProfileId":"a","status":"INACTIVE"},{"inferenceProfileId":"amazon.nova-pro-v1:0","status":"ACTIVE"},{"inferenceProfileId":"b"},{"inferenceProfileId":"b","status":"ACTIVE"},{"status":"ACTIVE"}]}"#)
        }
        let models = try await client().listModels()
        XCTAssertEqual(models, ["amazon.nova-pro-v1:0", "b"])
    }

    func testListModelsFollowsAtMostFiftyPages() async throws {
        FakeBedrock.reset { sent in
            sent.url.path == "/foundation-models"
                ? FakeBedrock.json(#"{"modelSummaries":[]}"#)
                : FakeBedrock.json(#"{"inferenceProfileSummaries":[],"nextToken":"again"}"#)
        }
        let models = try await client().listModels()
        XCTAssertTrue(models.isEmpty)
        XCTAssertEqual(FakeBedrock.requests.count, 51)
    }

    func testListModelsErrorsAreMapped() async {
        FakeBedrock.reset { _ in
            FakeBedrock.error(403, "AccessDeniedException", "User: arn:aws:iam::1:user/x is not authorized to perform: bedrock:ListFoundationModels")
        }
        do {
            _ = try await client().listModels()
            XCTFail("expected an error")
        } catch let error as LLMError {
            XCTAssertEqual(status(error), 403)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testListModelsRefreshesExpiredCredentialsLikeAStreamDoes() async throws {
        let source = RotatingSource(AWSCredentials(accessKeyID: "OLDKEY", secretAccessKey: "old"), SigV4Tests.withToken)
        let count = BedrockTestCounter()
        FakeBedrock.reset { sent in
            if count.next() == 1 { return FakeBedrock.error(403, "ExpiredTokenException", "The security token included in the request is expired") }
            return sent.url.path == "/foundation-models"
                ? FakeBedrock.json(#"{"modelSummaries":[{"modelId":"amazon.nova-pro-v1:0","inferenceTypesSupported":["ON_DEMAND"]}]}"#)
                : FakeBedrock.json(#"{"inferenceProfileSummaries":[]}"#)
        }
        let models = try await client(source: source).listModels()
        XCTAssertEqual(models, ["amazon.nova-pro-v1:0"])
        XCTAssertEqual(source.calls, [false, true, false], "the first call is refreshed once, then the next one asks for the cached credentials")
    }

    func testListModelsGivesUpAfterItsDeadline() async throws {
        BedrockClient.listModelsTimeout = 0.3
        FakeBedrock.reset { _ in .hang(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"modelSumm"#.utf8)) }
        let started = Date()
        do {
            _ = try await client().listModels()
            XCTFail("expected a timeout")
        } catch let error as LLMError {
            guard case .connection(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.hasPrefix("no answer within"), why)
            XCTAssertEqual(retry(error), "untilAvailable")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try await waitUntil("the request to be cancelled") { FakeBedrock.stops >= 1 }
    }

    func testListModelsRejectsAnUnexpectedReply() async {
        FakeBedrock.reset { _ in FakeBedrock.json("[1,2,3]") }
        do {
            _ = try await client().listModels()
            XCTFail("expected an error")
        } catch let error as LLMError {
            guard case .sse(let why) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(why, "unexpected reply from /foundation-models")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testModelInfoComesFromTheTable() async {
        FakeBedrock.reset { _ in .fail(.notConnectedToInternet) }
        let cases: [(String, Int)] = [
            (Self.sonnet45, 200_000),
            ("arn:aws:bedrock:us-west-2:123456789012:inference-profile/us.anthropic.claude-opus-4-1-20250805-v1:0", 200_000),
            ("global.anthropic.claude-opus-4-6-v1", 1_000_000),
            ("anthropic.claude-haiku-4-5-20251001-v1:0", 200_000),
            ("amazon.nova-pro-v1:0", 300_000),
            ("us.amazon.nova-lite-v1:0", 300_000),
            ("amazon.nova-micro-v1:0", 128_000),
            ("meta.llama3-3-70b-instruct-v1:0", 128_000),
            ("mistral.mistral-large-2407-v1:0", 128_000),
            ("us.deepseek.r1-v1:0", 128_000),
            ("openai.gpt-oss-120b-1:0", 128_000),
            ("qwen.qwen3-32b-v1:0", 128_000),
        ]
        for (model, window) in cases {
            let info = await client().modelInfo(model)
            XCTAssertEqual(info?.id, model)
            XCTAssertEqual(info?.contextWindow, window, model)
            XCTAssertEqual(BedrockModels.contextWindow(model), window, model)
            XCTAssertEqual(FallbackContextWindow.limit(for: model), window, "the context gauge follows the same table: \(model)")
        }
        XCTAssertTrue(FakeBedrock.requests.isEmpty, "the table needs no network call")
    }

    func testModelInfoUsesTheProfilesModelWhenNoneIsGiven() async {
        let info = await client(Self.profile("amazon.nova-micro-v1:0")).modelInfo(nil)
        XCTAssertEqual(info?.id, "amazon.nova-micro-v1:0")
        XCTAssertEqual(info?.contextWindow, 128_000)
        let empty = await client(Self.profile("amazon.nova-micro-v1:0")).modelInfo("")
        XCTAssertEqual(empty?.id, "amazon.nova-micro-v1:0")
    }

    func testUnknownModelsHaveNoWindow() async {
        let unknown = await client().modelInfo("arn:aws:bedrock:us-east-1:1:application-inference-profile/abc123")
        XCTAssertNotNil(unknown)
        XCTAssertNil(unknown?.contextWindow)
        let sonnet = await client().modelInfo(Self.sonnet45)
        XCTAssertEqual(sonnet?.maxTokens, 64_000)
    }

    func testFallbackTablesStillServeOtherProviders() {
        XCTAssertEqual(FallbackContextWindow.limit(for: "gpt-4o"), 128_000)
        XCTAssertEqual(FallbackContextWindow.limit(for: "anthropic/claude-sonnet-4.5"), 200_000)
        XCTAssertNil(BedrockModels.contextWindow("claude-sonnet-4-5"))
    }
}

// MARK: - ProviderClients

/// ProviderClients picks the client by profile kind and wires Bedrock to the app's credential source.
/// It mutates a process-wide hook, which each test puts back.
final class ProviderClientsTests: XCTestCase {
    func testBedrockProfilesGetABedrockClientWithTheAppsCredentials() {
        let previous = ProviderClients.awsCredentials
        defer { ProviderClients.awsCredentials = previous }
        let asked = BedrockTestBox<[String?]>([])
        ProviderClients.awsCredentials = { profile in
            asked.update { $0.append(profile.awsProfile) }
            return StaticAWSCredentialSource(SigV4Tests.noToken)
        }
        let bedrock = ProviderProfile(kind: .bedrock, name: "B", baseURL: "", model: "amazon.nova-pro-v1:0",
                                      awsProfile: "dsh-bedrock", awsRegion: "us-east-1")
        XCTAssertTrue(ProviderClients.make(bedrock) is BedrockClient)
        XCTAssertEqual(asked.current, ["dsh-bedrock"])

        let keyed = ProviderProfile(kind: .bedrock, name: "B", baseURL: "", apiKey: "bedrock-api-key-x",
                                    model: "amazon.nova-pro-v1:0", awsRegion: "us-east-1")
        let client = ProviderClients.make(keyed) as? BedrockClient
        XCTAssertEqual(client?.usesAPIKey, true)
        XCTAssertEqual(asked.current.count, 1, "an API-key profile needs no AWS credentials")

        let openAI = ProviderClients.make(ProviderProfile(kind: .openAI, name: "O", baseURL: "https://api.openai.com/v1", model: "gpt-4o"))
        XCTAssertTrue(openAI is OpenAIClient)
        XCTAssertEqual(openAI.profile.model, "gpt-4o")
    }

    func testWithoutACredentialHookBedrockAsksForASignIn() async {
        let previous = ProviderClients.awsCredentials
        defer { ProviderClients.awsCredentials = previous }
        ProviderClients.awsCredentials = nil
        let profile = ProviderProfile(kind: .bedrock, name: "B", baseURL: "", model: "amazon.nova-pro-v1:0",
                                      awsProfile: "p", awsRegion: "us-east-1")
        let client = ProviderClients.make(profile)
        do {
            for try await _ in client.stream(LLMRequest(systemPrompt: "s", messages: [.user("hi")], tools: [], model: "")) {}
            XCTFail("expected the sign-in request")
        } catch {
            XCTAssertEqual(RequestRetry.disposition(for: error), .fail)
            XCTAssertTrue(error.localizedDescription.contains("sign-in"), error.localizedDescription)
        }
    }
}

// MARK: - Mapping AWS errors

/// `BedrockError` and its mapping onto `LLMError`, without a network: how a type is normalised, which
/// refusals mean "credentials", "clock" or "your key", and what counts as a context overflow.
final class BedrockErrorMappingTests: XCTestCase {
    private typealias AWSError = BedrockClient.BedrockError

    private func client(awsProfile: String? = "vision", apiKey: String? = nil, model: String = "the-model") -> BedrockClient {
        BedrockClient(profile: ProviderProfile(kind: .bedrock, name: "B", baseURL: "", apiKey: apiKey, model: model,
                                               awsProfile: awsProfile, awsRegion: "eu-west-1"),
                      credentials: nil)
    }

    func testTheKindIsTheTypeWithoutItsNamespaceOrSuffix() {
        let cases = [
            ("ValidationException:http://internal.amazon.com/coral/com.amazon.bedrock/", "validationexception"),
            ("com.amazon.coral.service#UnrecognizedClientException", "unrecognizedclientexception"),
            ("aws.protocoltests#Some:http://x/y#z", "some"),
            ("  ThrottlingException \n", "throttlingexception"),
            ("", ""),
        ]
        for (type, kind) in cases {
            XCTAssertEqual(AWSError(status: 400, type: type, message: "").kind, kind, type)
        }
    }

    func testWhichRefusalsMeanTheCredentialsRanOut() {
        let expired: [(Int, String, String)] = [
            (400, "ExpiredTokenException", ""), (403, "ExpiredToken", ""), (403, "UnrecognizedClientException", ""),
            (403, "InvalidClientTokenId", ""), (400, "TokenRefreshRequired", ""),
            (403, "", "The security token included in the request is expired"), (403, "AccessDenied", "The security token included in the request is invalid."),
            (400, "", "Token has expired and refresh failed"),
        ]
        for (status, type, message) in expired {
            XCTAssertTrue(AWSError(status: status, type: type, message: message).expiredCredentials, "\(status) \(type) \(message)")
        }
        let other: [(Int, String, String)] = [
            (500, "ExpiredTokenException", ""), (401, "ExpiredTokenException", ""), (0, "ExpiredTokenException", ""),
            (403, "AccessDeniedException", "You don't have access."), (400, "ValidationException", "bad"),
        ]
        for (status, type, message) in other {
            XCTAssertFalse(AWSError(status: status, type: type, message: message).expiredCredentials, "\(status) \(type) \(message)")
        }
    }

    func testWhichRefusalsMeanTheClockIsOff() {
        XCTAssertTrue(AWSError(status: 403, type: "RequestTimeTooSkewed", message: "").clockSkew)
        XCTAssertTrue(AWSError(status: 403, type: "RequestExpired", message: "").clockSkew)
        XCTAssertTrue(AWSError(status: 403, type: "InvalidSignatureException", message: "Signature expired: x").clockSkew)
        XCTAssertTrue(AWSError(status: 403, type: "InvalidSignatureException", message: "Signature not yet current: x").clockSkew)
        XCTAssertFalse(AWSError(status: 403, type: "InvalidSignatureException", message: "The request signature we calculated does not match").clockSkew)
        XCTAssertFalse(AWSError(status: 403, type: "AccessDeniedException", message: "Signature expired").clockSkew)
    }

    func testEveryAuthenticationRefusalIsPermanentAndNamesTheProfile() {
        let types = ["InvalidSignatureException", "IncompleteSignatureException", "MissingAuthenticationTokenException", "SignatureDoesNotMatch",
                     "ExpiredTokenException", "RequestTimeTooSkewed"]
        for type in types {
            let mapped = client().map(AWSError(status: 403, type: type, message: "nope"), model: "m")
            guard case .rejected(let status, let message, let body, let permanent) = mapped else { return XCTFail("\(type): \(mapped)") }
            XCTAssertEqual(status, 403, type)
            XCTAssertTrue(permanent, type)
            XCTAssertTrue(message.contains("profile \"vision\""), message)
            XCTAssertTrue(message.contains("aws login --profile vision"), message)
            XCTAssertEqual(body, "\(type): nope")
        }
        // Inside a stream there is no HTTP status: it is reported as the 403 it is. (Expired credentials need
        // a 400 or 403 to be recognised as such; a signature refusal does not.)
        guard case .rejected(let status, _, _, _) = client().map(AWSError(status: 0, type: "InvalidSignatureException", message: "x"), model: "m")
        else { return XCTFail("expected a rejection") }
        XCTAssertEqual(status, 403)
        guard case .http(let streamed, _) = client().map(AWSError(status: 0, type: "ExpiredTokenException", message: "x"), model: "m")
        else { return XCTFail("expected a plain http error") }
        XCTAssertEqual(streamed, 500)
        // A route with no AWS profile at all names "default".
        guard case .rejected(_, let message, _, _) = client(awsProfile: nil).map(AWSError(status: 403, type: "SignatureDoesNotMatch", message: "x"), model: "m")
        else { return XCTFail("expected a rejection") }
        XCTAssertTrue(message.contains("profile \"default\""), message)
    }

    func testARejectedApiKeyIsBlamedOnTheKeyButAPlainAccessDeniedIsNot() {
        let keyed = client(awsProfile: nil, apiKey: "bedrock-api-key-x")
        for (status, type, message) in [(401, "", "Unauthorized"), (403, "InvalidSignatureException", "bad"), (403, "AccessDeniedException", "invalid API key"),
                                        (403, "AccessDeniedException", "Bearer token rejected"), (403, "AccessDeniedException", "Authentication failed")] {
            guard case .rejected(let code, let text, _, let permanent) = keyed.map(AWSError(status: status, type: type, message: message), model: "m")
            else { return XCTFail("\(status) \(type)") }
            XCTAssertEqual(code, status)
            XCTAssertTrue(permanent)
            XCTAssertTrue(text.hasPrefix("Bedrock did not accept the API key"), text)
            XCTAssertTrue(text.contains("12 hours"), text)
        }
        guard case .rejected(let code, let text, _, let permanent) = keyed.map(AWSError(status: 403, type: "AccessDeniedException", message: "no access to the model"), model: "m")
        else { return XCTFail("expected a rejection") }
        XCTAssertEqual(code, 403)
        XCTAssertFalse(permanent)
        XCTAssertTrue(text.contains("refused access to m in eu-west-1"), text)
        // The same words on a route that signs with AWS are not about a key.
        let signed = client().map(AWSError(status: 401, type: "", message: "Unauthorized"), model: "m")
        XCTAssertFalse(signed.localizedDescription.contains("API key"), signed.localizedDescription)
    }

    func testTheModelAndRegionAppearInTheMessagesThatNeedThem() {
        let c = client(model: "profile-model")
        func message(_ type: String, status: Int = 400, _ text: String = "detail") -> String {
            c.map(AWSError(status: status, type: type, message: text), model: "asked-model").localizedDescription
        }
        XCTAssertEqual(message("ThrottlingException"), "Bedrock is throttling requests for asked-model (detail).")
        XCTAssertEqual(message("ServiceQuotaExceededException"), "Bedrock is throttling requests for asked-model (detail).")
        XCTAssertEqual(message("TooManyRequestsException"), "Bedrock is throttling requests for asked-model (detail).")
        XCTAssertEqual(message("ModelNotReadyException"), "asked-model is not ready on Bedrock yet (detail).")
        XCTAssertEqual(message("ServiceUnavailableException"), "Bedrock is unavailable (detail).")
        XCTAssertEqual(message("ModelTimeoutException"), "asked-model timed out on Bedrock (detail).")
        for type in ["InternalServerException", "InternalFailure", "ModelErrorException", "ModelStreamErrorException"] {
            XCTAssertEqual(message(type), "Bedrock failed while running asked-model (detail).", type)
        }
        XCTAssertTrue(message("ResourceNotFoundException").hasPrefix("Bedrock has no model \"asked-model\" in eu-west-1 (detail)."))
        XCTAssertEqual(message("ValidationException"), "Bedrock rejected the request: detail")
    }

    func testAnErrorWithNoMessageFallsBackToItsTypeAndAnUnknownOneToAPlainHttpError() {
        let c = client()
        guard case .rejected(_, let message, let body, _) = c.map(AWSError(status: 429, type: "ThrottlingException", message: ""), model: "m")
        else { return XCTFail("expected a rejection") }
        XCTAssertTrue(message.contains("(ThrottlingException)"), message)
        XCTAssertEqual(body, "ThrottlingException: ThrottlingException")
        guard case .http(let code, let plain) = c.map(AWSError(status: 0, type: "", message: "the stream broke"), model: "m")
        else { return XCTFail("expected an http error") }
        XCTAssertEqual(code, 500, "no status inside a stream")
        XCTAssertEqual(plain, "the stream broke")
    }

    func testWhatCountsAsAContextOverflow() {
        let overflow = [
            "prompt is too long: 215000 tokens > 200000 maximum",
            "Input is too long for requested model.",
            "input length and `max_tokens` exceed context limit: 180000 + 32000 > 200000",
            "The model's context window is exceeded",
            "Too many input tokens",
            "maximum context length is 131072 tokens",
        ]
        for text in overflow { XCTAssertTrue(BedrockClient.isOverflow(text), text) }
        let notOverflow = [
            "The maximum tokens you requested exceeds the model limit of 8192.",
            "Too many output tokens requested",
            "The format of the value at messages.3 is invalid.",
            "Malformed input request",
            "Requested max_tokens exceeds the limit for this input length", // about the output, though it says "input"
            "The input and output tokens you asked for exceed the model's limit", // "output tokens" and no window named
            "",
        ]
        for text in notOverflow { XCTAssertFalse(BedrockClient.isOverflow(text), text) }
    }

    func testTheLimitAnOverflowNames() {
        let cases: [(String, Int?)] = [
            ("prompt is too long: 215000 tokens > 200000 maximum", 200_000),
            ("input length and `max_tokens` exceed context limit: 180000 + 32000 > 200000", 200_000),
            ("This model's maximum context length is 131072 tokens", 131_072),     // OpenAI-style wording, shared with the other client
            ("the maximum length of 65536 was exceeded", 65_536),
            ("maximum context length of 4096", 4096),
            ("too long: 12 > 34", nil),                                              // fewer than four digits is not a window
            ("nothing to see", nil),
            ("> 99999999999", nil),                                                  // beyond Int32
        ]
        for (text, limit) in cases { XCTAssertEqual(BedrockClient.overflowLimit(text), limit, text) }
    }

    func testCopiesOfAClientShareWhatItLearnsAboutTheClock() async throws {
        // Clients are passed around by value (the engine keeps one, retries make more): the skew learned
        // by one is used by all.
        let count = BedrockTestCounter()
        FakeBedrock.reset { _ in
            count.next() == 1
                ? FakeBedrock.error(403, "RequestTimeTooSkewed", "too far", headers: ["Date": FakeBedrock.httpDate(SigV4Tests.now.addingTimeInterval(120))])
                : FakeBedrock.reply(EventStreamFrames.stop("end_turn"))
        }
        let session = FakeBedrock.makeSession()
        defer { session.invalidateAndCancel(); FakeBedrock.reset(nil) }
        let profile = ProviderProfile(kind: .bedrock, name: "B", baseURL: "", model: "amazon.nova-pro-v1:0", awsProfile: "p", awsRegion: "us-east-1")
        let original = BedrockClient(profile: profile, credentials: StaticAWSCredentialSource(SigV4Tests.noToken), session: session, clock: { SigV4Tests.now })
        let copy = original
        for try await _ in original.stream(LLMRequest(systemPrompt: "s", messages: [.user("hi")], tools: [], model: "")) {}
        for try await _ in copy.stream(LLMRequest(systemPrompt: "s", messages: [.user("hi")], tools: [], model: "")) {}
        XCTAssertEqual(FakeBedrock.requests.map { $0.header("X-Amz-Date") }, ["20260929T123456Z", "20260929T123656Z", "20260929T123656Z"])
    }
}
