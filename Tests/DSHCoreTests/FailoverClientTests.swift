import XCTest
@testable import DSHCore

/// A client that answers from a script and counts its calls.
private final class FailoverScript: ProviderClient, @unchecked Sendable {
    enum Step { case reply(String), fail(Error), failAfter(String, Error) }
    let profile: ProviderProfile
    private let lock = NSLock()
    private var steps: [Step]
    private var _models: [String] = []

    /// What the server says it serves (nil: it doesn't say).
    private let served: String?

    init(_ name: String, model: String = "m", served: String? = nil, _ steps: [Step]) {
        profile = ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(name.lowercased()).test/v1", model: model)
        self.served = served
        self.steps = steps
    }

    var calls: Int { lock.withLock { _models.count } }
    var models: [String] { lock.withLock { _models } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let step: Step = lock.withLock {
            _models.append(request.model)
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        return AsyncThrowingStream { continuation in
            switch step {
            case .reply(let text):
                continuation.yield(.text(text))
                continuation.yield(.done(calls: [], finish: "stop", usage: nil))
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .failAfter(let text, let error):
                continuation.yield(.text(text))
                continuation.finish(throwing: error)
            }
        }
    }

    func listModels() async throws -> [String] { [profile.model] }
    func modelInfo(_ model: String?) async -> ModelInfo? { served.map { ModelInfo(id: $0, servedModels: [$0]) } }
}

/// Notices several threads report.
private final class FailoverNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [FailoverNotice] = []
    func add(_ notice: FailoverNotice) { lock.withLock { seen.append(notice) } }
    var all: [FailoverNotice] { lock.withLock { seen } }
}

/// A clock a test moves by hand.
private final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

final class FailoverClientTests: XCTestCase {
    private let request = LLMRequest(systemPrompt: "s", messages: [.user("hi")], tools: [], model: "primary-model")

    private func run(_ client: FailoverClient) async throws -> String {
        var text = ""
        for try await event in client.stream(request) {
            if case .text(let t) = event { text += t }
        }
        return text
    }

    func testAPrimaryThatDoesNotAnswerHandsTheTurnToTheFirstHealthyBackup() async throws {
        let primary = FailoverScript("Spark", model: "primary-model", [.fail(LLMError.http(503, "overloaded"))])
        let dead = FailoverScript("Dead", model: "dead-model", [.fail(LLMError.connection("refused"))])
        let healthy = FailoverScript("Kimi Code", model: "kimi-for-coding", [.reply("from the backup")])
        let notices = FailoverNotices()
        let client = FailoverClient(primary: primary, backups: [dead, healthy], onFailover: notices.add)

        let text = try await run(client)
        XCTAssertEqual(text, "from the backup")
        XCTAssertEqual(primary.calls, 1)
        XCTAssertEqual(dead.calls, 1)
        XCTAssertEqual(healthy.models, ["kimi-for-coding"], "a backup is asked for its own model")
        XCTAssertEqual(notices.all, [FailoverNotice(primary: "Spark", backup: "Kimi Code", reason: "HTTP 503: overloaded")])
        XCTAssertEqual(notices.all.first?.text, "Spark didn't answer (HTTP 503: overloaded), so this turn ran on Kimi Code.")
    }

    func testEveryKindOfServerFailureFailsOver() {
        let yes: [Error] = [LLMError.connection("x"), LLMError.sse("cut off"), URLError(.timedOut), URLError(.cannotConnectToHost),
                            LLMError.http(401, ""), LLMError.http(403, ""), LLMError.http(404, "model gone"), LLMError.http(408, ""),
                            LLMError.http(429, ""), LLMError.http(500, ""), LLMError.http(502, ""), LLMError.http(503, ""),
                            LLMError.rejected(status: 403, message: "m", body: "", permanent: true)]
        let no: [Error] = [LLMError.http(400, "bad request"), LLMError.overflow(limit: 1, detail: ""), LLMError.noModel,
                           CancellationError(), URLError(.cancelled), LLMError.unsupported("x")]
        for error in yes { XCTAssertTrue(FailoverClient.failsOver(error), "\(error)") }
        for error in no { XCTAssertFalse(FailoverClient.failsOver(error), "\(error)") }
    }

    func testARequestTheServerRejectsDoesNotFailOver() async {
        let primary = FailoverScript("Spark", [.fail(LLMError.http(400, "bad request"))])
        let backup = FailoverScript("Backup", [.reply("x")])
        let client = FailoverClient(primary: primary, backups: [backup])
        do {
            _ = try await run(client)
            XCTFail("a malformed request is the request's fault")
        } catch {
            guard case LLMError.http(400, _) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(backup.calls, 0)
    }

    func testWhenEveryoneFailsThePrimarysErrorComesOut() async {
        let primary = FailoverScript("Spark", [.fail(LLMError.connection("primary down"))])
        let backup = FailoverScript("Backup", [.fail(LLMError.http(503, "also down"))])
        let notices = FailoverNotices()
        let client = FailoverClient(primary: primary, backups: [backup], onFailover: notices.add)
        do {
            _ = try await run(client)
            XCTFail("nobody answered")
        } catch {
            guard case LLMError.connection("primary down") = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(notices.all.isEmpty)
    }

    func testNeverMidStream() async {
        let primary = FailoverScript("Spark", [.failAfter("half an ans", LLMError.sse("cut off"))])
        let backup = FailoverScript("Backup", [.reply("x")])
        let client = FailoverClient(primary: primary, backups: [backup])
        do {
            _ = try await run(client)
            XCTFail("the cut-off answer's error comes out")
        } catch {
            guard case LLMError.sse = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(backup.calls, 0, "once the primary has started answering, there's no failover")
    }

    func testAPrimaryThatJustFailedIsTriedLastForAMinute() async throws {
        let clock = HandClock()
        let primary = FailoverScript("Spark", [.fail(LLMError.connection("down")), .reply("back again")])
        let backup = FailoverScript("Backup", [.reply("from the backup")])
        let notices = FailoverNotices()
        let client = FailoverClient(primary: primary, backups: [backup], now: { clock.now }, onFailover: notices.add)

        _ = try await run(client)
        XCTAssertEqual(primary.calls, 1)
        // The next step of the same turn doesn't wait for the dead primary again.
        let second = try await run(client)
        XCTAssertEqual(second, "from the backup")
        XCTAssertEqual(primary.calls, 1)
        XCTAssertEqual(notices.all.count, 2)
        XCTAssertEqual(notices.all.last?.reason, "server unreachable (down)")
        // A minute later it is first again.
        clock.advance(FailoverClient.coolDown + 1)
        let third = try await run(client)
        XCTAssertEqual(third, "back again")
        XCTAssertEqual(primary.calls, 2)
    }

    func testABackupBoxThatSwitchedModelsIsAskedWhatItServesNow() async throws {
        // The backup was set up while its box served "qwen-27b"; it has switched to "qwen-flash" since.
        let primary = FailoverScript("Spark", [.fail(LLMError.connection("refused"))])
        let backup = FailoverScript("Spark 2", model: "qwen-27b", served: "qwen-flash",
                                    [.fail(LLMError.http(404, "The model `qwen-27b` does not exist.")), .reply("from flash")])
        let client = FailoverClient(primary: primary, backups: [backup])
        let text = try await run(client)
        XCTAssertEqual(text, "from flash")
        XCTAssertEqual(backup.models, ["qwen-27b", "qwen-flash"], "asked once, then the model it serves")

        // A backup that says it serves what was asked doesn't get the same request twice.
        let stale = FailoverScript("Spark 3", model: "qwen-27b", served: "qwen-27b", [.fail(LLMError.http(404, "gone"))])
        let other = FailoverScript("Kimi", [.reply("from kimi")])
        let again = FailoverClient(primary: FailoverScript("Spark", [.fail(LLMError.connection("refused"))]), backups: [stale, other])
        let answer = try await run(again)
        XCTAssertEqual(answer, "from kimi")
        XCTAssertEqual(stale.calls, 1)
    }

    func testWithoutBackupsTheClientIsThePrimaryItself() {
        let route = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local/v1", model: "m")
        XCTAssertTrue(ProviderClients.make(route) is OpenAIClient)
        XCTAssertTrue(ProviderClients.make(route, backups: []) is OpenAIClient)
        let wrapped = ProviderClients.make(route, backups: [ProviderProfile(kind: .openAICompat, name: "B", baseURL: "http://b.local/v1", model: "b")])
        XCTAssertTrue(wrapped is FailoverClient)
        XCTAssertEqual(wrapped.profile, route, "it presents as the primary")
    }
}
