import XCTest
@testable import VisionHarnessCore

/// The shared types the fleet and the Bedrock provider stand on: saved routes stay readable, a
/// client can mark an error permanent, a fleet subagent can give up early, and a provider's opaque
/// state rides on the assistant message.
final class ProviderFoundationTests: XCTestCase {

    // MARK: Saved routes

    func testRoutesSavedBeforeBedrockAndTheFleetStillDecode() throws {
        let old = #"""
        [{"kind":"openAICompat","name":"Spark","baseURL":"http://spark:8002/v1","model":"qwen","temperature":0.2,
          "contextWindow":262144,"reasoningEffort":"high"}]
        """#
        let profiles = try JSONDecoder().decode([ProviderProfile].self, from: Data(old.utf8))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].kind, .openAICompat)
        XCTAssertEqual(profiles[0].contextWindow, 262_144)
        XCTAssertNil(profiles[0].awsProfile)
        XCTAssertNil(profiles[0].awsRegion)
        XCTAssertNil(profiles[0].subagentWorker)
        XCTAssertFalse(profiles[0].isSubagentWorker)
        XCTAssertNil(profiles[0].subagentParallel)
    }

    func testABedrockRouteWithWorkerSettingsRoundTrips() throws {
        let route = ProviderProfile(kind: .bedrock, name: "Amazon Bedrock",
                                    baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                    model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
                                    awsProfile: "dsh-bedrock", awsRegion: "us-east-1",
                                    subagentWorker: true, subagentParallel: 3)
        let again = try JSONDecoder().decode(ProviderProfile.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(again, route)
        XCTAssertTrue(again.isSubagentWorker)
        XCTAssertEqual(again.subagentParallel, 3)
        XCTAssertFalse(again.isSelfHosted, "Bedrock is a hosted service")
    }

    func testTheManualKindsLeaveOutBedrock() {
        XCTAssertFalse(ProviderProfile.Kind.manual.contains(.bedrock))
        XCTAssertTrue(ProviderProfile.Kind.allCases.contains(.bedrock))
    }

    // MARK: Permanent rejections

    func testAPermanentRejectionIsNeverRetriedWhateverItsStatus() {
        // A 404 from a self-hosted server that is swapping models heals itself; Bedrock's does not.
        let swapping = LLMError.http(404, "The model `x` does not exist")
        XCTAssertEqual(RequestRetry.disposition(for: swapping), .untilAvailable)
        let bedrock = LLMError.rejected(status: 404, message: "Bedrock has no model x", body: "The model `x` does not exist", permanent: true)
        XCTAssertEqual(RequestRetry.disposition(for: bedrock), .fail)
    }

    func testARejectionThatIsNotPermanentFollowsItsStatus() {
        let throttled = LLMError.rejected(status: 429, message: "Bedrock is throttling", body: "ThrottlingException: slow down", permanent: false)
        XCTAssertEqual(RequestRetry.disposition(for: throttled), .untilAvailable)
        let denied = LLMError.rejected(status: 403, message: "access denied", body: "AccessDeniedException", permanent: false)
        XCTAssertEqual(RequestRetry.disposition(for: denied), .fail)
        let broken = LLMError.rejected(status: 500, message: "model error", body: "InternalServerException", permanent: false)
        XCTAssertEqual(RequestRetry.disposition(for: broken), .limited(RequestRetry.serverErrorRetries))
    }

    func testARejectionShowsItsOwnWordsAndTheServersInTheStatusLine() {
        let error = LLMError.rejected(status: 429, message: "Bedrock is throttling requests for m.", body: "ThrottlingException: slow down", permanent: false)
        XCTAssertEqual(error.localizedDescription, "Bedrock is throttling requests for m.")
        XCTAssertEqual(RequestRetry.reason(for: error), "HTTP 429: ThrottlingException: slow down")
    }

    // MARK: Failure cap

    func testAFailureCapMakesAFleetSubagentGiveUpEarly() async {
        let client = FlakyClient(failures: 100, error: LLMError.connection("down"), turns: [])
        let engine = makeEngine(client, retry: RetryPolicy(delay: { _ in 0 }, maxFailures: 2))
        do {
            _ = try await engine.run(messages: [], userText: "go", sink: { _ in })
            XCTFail("expected the failure to surface")
        } catch {
            XCTAssertEqual(client.calls, 3, "the first attempt plus two retries, then it gives up")
        }
    }

    func testWithoutACapAnOutageIsWaitedOut() async throws {
        let client = FlakyClient(failures: 6, error: LLMError.connection("down"), turns: [.init(text: "back")])
        let engine = makeEngine(client, retry: RetryPolicy(delay: { _ in 0 }))
        let result = try await engine.run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(result.finalText, "back")
        XCTAssertEqual(client.calls, 7)
    }

    // MARK: Provider state

    func testProviderStateRidesOnTheAssistantMessageAndComesBackNextTurn() async throws {
        let client = StatefulClient(replies: [("first", "signed-reasoning-1"), ("second", nil)])
        let engine = makeEngine(client, retry: .standard)
        let first = try await engine.run(messages: [], userText: "one", sink: { _ in })
        XCTAssertEqual(first.messages.last?.role, .assistant)
        XCTAssertEqual(first.messages.last?.providerState, "signed-reasoning-1")

        _ = try await engine.run(messages: first.messages, userText: "two", sink: { _ in })
        let sent = client.requests.last!.messages
        XCTAssertEqual(sent.first { $0.role == .assistant }?.providerState, "signed-reasoning-1",
                       "the state is handed back verbatim with the message it belongs to")
    }

    func testMessagesWithoutProviderStateEncodeAsBefore() throws {
        let plain = try JSONEncoder().encode(LLMMessage.assistant("hi"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("providerState"))
        let withState = LLMMessage(role: .assistant, content: "hi", providerState: "abc")
        let back = try JSONDecoder().decode(LLMMessage.self, from: JSONEncoder().encode(withState))
        XCTAssertEqual(back.providerState, "abc")
    }

    // MARK: Usage

    func testUsageSumsKeepCachedTokensOnlyWhenSomeoneReportedThem() {
        let a = LLMUsage(promptTokens: 100, completionTokens: 10)
        let b = LLMUsage(promptTokens: 50, completionTokens: 5, cachedTokens: 40)
        XCTAssertEqual(LLMUsage.sum(a, a), LLMUsage(promptTokens: 200, completionTokens: 20))
        XCTAssertEqual(LLMUsage.sum(a, b)?.cachedTokens, 40)
        XCTAssertEqual(LLMUsage.sum(b, b)?.cachedTokens, 80)
        XCTAssertEqual(LLMUsage.sum(nil, b), b)
        XCTAssertEqual(LLMUsage.sum(a, nil), a)
        XCTAssertNil(LLMUsage.sum(nil, nil))
    }

    // MARK: The provider factory

    func testTheFactoryPicksTheClientByRouteKind() {
        let spark = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark:8002/v1", model: "qwen")
        XCTAssertTrue(ProviderClients.make(spark) is OpenAIClient)
        let bedrock = ProviderProfile(kind: .bedrock, name: "Bedrock", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                      model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", awsProfile: "dsh-bedrock", awsRegion: "us-east-1")
        XCTAssertTrue(ProviderClients.make(bedrock) is BedrockClient)
        XCTAssertEqual(ProviderClients.make(bedrock).profile, bedrock, "the client carries the route it was made for")
    }

    func testTheFactoryAsksForAWSCredentialsExceptForAnAPIKeyRoute() {
        nonisolated(unsafe) var asked: [String] = []
        let lock = NSLock()
        ProviderClients.awsCredentials = { profile in
            lock.lock(); asked.append(profile.awsProfile ?? "-"); lock.unlock()
            return StaticAWSCredentialSource(AWSCredentials(accessKeyID: "AKID", secretAccessKey: "secret"))
        }
        defer { ProviderClients.awsCredentials = nil }
        _ = ProviderClients.make(ProviderProfile(kind: .bedrock, name: "B", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                                 model: "m", awsProfile: "dsh-bedrock", awsRegion: "us-east-1"))
        // A route that authenticates with a Bedrock API key never touches the AWS CLI.
        _ = ProviderClients.make(ProviderProfile(kind: .bedrock, name: "K", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                                 model: "m", awsRegion: "us-east-1"))
        var withKey = ProviderProfile(kind: .bedrock, name: "K2", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                      model: "m", awsRegion: "us-east-1")
        withKey.apiKey = "bedrock-api-key-abc"
        _ = ProviderClients.make(withKey)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(asked, ["dsh-bedrock", "-"], "asked for the profile route, and for the route with neither a profile nor a key; not for the API-key route")
    }

    // MARK: Helpers

    private func makeEngine(_ client: any LLMClient, retry: RetryPolicy) -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        return Engine(client: client, registry: ToolRegistry(tools: []), systemPrompt: "system",
                      config: .init(maxIterations: 3, toolTimeout: 5, model: "test", retry: retry),
                      workspace: root, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                      permissionGate: { _, _, _ in true })
    }
}

/// Answers with fixed replies, each with the provider state it wants stored, and remembers what it was sent.
private final class StatefulClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(String, String?)]
    private(set) var requests: [LLMRequest] = []

    init(replies: [(String, String?)]) { self.replies = replies }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let reply = replies.isEmpty ? ("done", nil) : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(reply.0))
            continuation.yield(.done(calls: [], finish: "stop", usage: nil, providerState: reply.1))
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { [] }
}
