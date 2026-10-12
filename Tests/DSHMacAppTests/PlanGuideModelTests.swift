import XCTest
import DSHCore
@testable import DSHMacApp

@MainActor
final class FakePlanBackend: PlanGuideBackend {
    var listResult: Result<[String], Error> = .success([])
    var pingError: Error?
    var helloText = "Hi there!"
    private(set) var calls: [String] = []
    private(set) var hellos: [ProviderProfile] = []
    private(set) var opened: [URL] = []

    func listModels(route: ProviderProfile) async throws -> [String] {
        calls.append("list:\(route.baseURL):\(route.apiKey ?? "-")")
        return try listResult.get()
    }

    func ping(route: ProviderProfile, model: String) async throws {
        calls.append("ping:\(model)")
        if let pingError { throw pingError }
    }

    func sayHello(route: ProviderProfile) async throws -> String {
        hellos.append(route)
        return helloText
    }

    func open(_ url: URL) { opened.append(url) }
}

@MainActor
final class PlanGuideModelTests: XCTestCase {
    private var suites: [String] = []
    private var secrets = MemorySecretStore()

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        try await super.tearDown()
    }

    private func config(_ routes: [ProviderProfile] = []) -> AppConfig {
        let suite = "dsh.planguide.test.\(UUID().uuidString)"
        suites.append(suite)
        secrets = MemorySecretStore()
        let config = AppConfig(defaults: UserDefaults(suiteName: suite)!, secrets: secrets)
        config.providers = routes
        config.activeRoute = routes.first?.routeID
        return config
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testTheQwenCodingPlanEndToEnd() async throws {
        let backend = FakePlanBackend()
        let c = config()
        let guide = PlanGuideModel(backend: backend, config: c)
        XCTAssertEqual(guide.role, .primary, "nothing leads yet")
        XCTAssertFalse(guide.canAdvance)
        guide.choose("qwen-coding")
        guide.regionID = "china"
        XCTAssertFalse(guide.isPrivate, "an online service")
        guide.next()
        XCTAssertEqual(guide.page, .key)
        guide.openKeyPage()
        XCTAssertEqual(backend.opened.first?.absoluteString, "https://bailian.console.aliyun.com/cn-beijing/subscription/coding-plan")
        guide.next()
        XCTAssertEqual(guide.page, .paste)
        XCTAssertFalse(guide.canAdvance)
        guide.key = "sk-12345"
        XCTAssertNotNil(guide.keyProblem, "a pay-as-you-go key on the Coding Plan")
        guide.key = "  sk-sp-12345 \n"
        XCTAssertNil(guide.keyProblem)
        guide.next()
        XCTAssertEqual(guide.page, .check)
        try await waitUntil("the check") { guide.checked }
        XCTAssertEqual(backend.calls, ["ping:qwen3.7-plus"], "the Coding Plan's /models isn't relied on")
        guide.next()
        XCTAssertEqual(guide.selectedModel, "qwen3.7-plus", "the recommended model is picked")
        guide.pick("qwen3-coder-plus")
        guide.next()
        guide.next()
        try await waitUntil("the hello") { guide.hello != nil }
        let route = try XCTUnwrap(guide.saved)
        XCTAssertEqual(route.kind, .openAICompat)
        XCTAssertEqual(route.name, "Qwen Coding Plan (China)")
        XCTAssertEqual(route.baseURL, "https://coding.dashscope.aliyuncs.com/v1")
        XCTAssertEqual(route.model, "qwen3-coder-plus")
        XCTAssertEqual(route.interactiveOnly, true, "the plan's terms")
        XCTAssertNil(route.isPrivate, "the default (not private) isn't stored as a choice")
        XCTAssertFalse(route.isPrivateRoute)
        XCTAssertNil(route.apiKey)
        XCTAssertEqual(c.apiKey(for: route), "sk-sp-12345", "the key, trimmed, is in the secure store")
        XCTAssertEqual(c.mainRoute?.routeID, route.routeID)
        XCTAssertEqual(c.interactiveOnlyMain?.routeID, route.routeID)
        XCTAssertEqual(backend.hellos.first?.apiKey, "sk-sp-12345")
    }

    func testAPlanThatListsModelsShowsThemAndFallsBackWhenItCannot() async throws {
        let backend = FakePlanBackend()
        backend.listResult = .success(["gpt-4.1", "gpt-5.2", "whisper-1"])
        let existing = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8002/v1", model: "q")
        let c = config([existing])
        let guide = PlanGuideModel(backend: backend, config: c)
        XCTAssertEqual(guide.role, .justAdd, "a primary exists: just add it")
        guide.choose("openai")
        guide.key = "sk-proj-abc"
        guide.go(.check)
        try await waitUntil("the check") { guide.checked }
        XCTAssertEqual(guide.models.map(\.id), ["gpt-5.2", "gpt-4.1"])
        XCTAssertEqual(guide.selectedModel, "gpt-5.2")
        guide.role = .backup
        guide.go(.done)
        try await waitUntil("saved") { guide.saved != nil }
        let route = try XCTUnwrap(c.providers.first { $0.name == "OpenAI" })
        XCTAssertEqual(route.kind, .openAI)
        XCTAssertTrue(route.isBackup)
        XCTAssertEqual(c.mainRoute?.name, "Spark")

        // /models not there (404): a one-word message checks the key instead.
        let fallback = FakePlanBackend()
        fallback.listResult = .failure(LLMError.http(404, "not found"))
        let second = PlanGuideModel(backend: fallback, config: config())
        second.choose("moonshot-api")
        second.key = "sk-abc"
        second.go(.check)
        try await waitUntil("the check") { second.checked || second.checkError != nil }
        XCTAssertTrue(second.checked)
        XCTAssertEqual(fallback.calls.last, "ping:kimi-k2.7-code")
        XCTAssertEqual(second.models.map(\.id), ["kimi-k2.7-code"])
    }

    func testAWrongKeyIsExplainedAndTheUserCanTurnPrivacyOn() async throws {
        let backend = FakePlanBackend()
        backend.pingError = LLMError.http(401, "invalid api key")
        let guide = PlanGuideModel(backend: backend, config: config())
        guide.choose("kimi-code")
        guide.key = "sk-wrong"
        guide.go(.check)
        try await waitUntil("the check") { guide.checkError != nil }
        XCTAssertEqual(guide.checkError, "The key wasn't accepted — check it's a Kimi Code (subscription) key for the International region.")
        XCTAssertFalse(guide.canAdvance)
        backend.pingError = nil
        guide.runCheck()
        try await waitUntil("the second check") { guide.checked }
        guide.go(.model)
        guide.isPrivate = true
        guide.go(.done)
        try await waitUntil("saved") { guide.saved != nil }
        XCTAssertEqual(guide.saved?.isPrivate, true, "an explicit choice is stored")
        XCTAssertNil(guide.saved?.interactiveOnly)
    }

    // MARK: Running it again

    private func addKimi(_ c: AppConfig, key: String, role: PlanRole? = nil) async throws -> ProviderProfile {
        let guide = PlanGuideModel(backend: FakePlanBackend(), config: c)
        guide.choose("kimi-code")
        guide.key = key
        guide.go(.check)
        try await waitUntil("the check") { guide.checked }
        if let role { guide.role = role }
        guide.go(.done)
        try await waitUntil("saved") { guide.saved != nil }
        return try XCTUnwrap(guide.saved)
    }

    func testTheSamePlanAndKeyAgainKeepsTheRoutesOwnSettings() async throws {
        let spark = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8002/v1", model: "q")
        let c = config([spark])
        let first = try await addKimi(c, key: "sk-kimi-1", role: .subagent)
        // The user tunes it in Settings.
        let index = try XCTUnwrap(c.providers.firstIndex { $0.routeID == first.routeID })
        c.providers[index].contextWindow = 200_000
        c.providers[index].reasoningEffort = "max"
        c.providers[index].subagentParallel = 5

        let again = try await addKimi(c, key: "sk-kimi-1")
        XCTAssertEqual(again.routeID, first.routeID)
        XCTAssertEqual(c.providers.count, 2)
        let route = try XCTUnwrap(c.providers.first { $0.routeID == first.routeID })
        XCTAssertEqual(route.contextWindow, 200_000)
        XCTAssertEqual(route.reasoningEffort, "max")
        XCTAssertEqual(route.subagentParallel, 5)
        XCTAssertTrue(route.isSubagentWorker, "the role stays")
        XCTAssertEqual(c.mainRoute?.name, "Spark")
    }

    func testASecondKeyIsASecondRoute() async throws {
        let c = config()
        let first = try await addKimi(c, key: "sk-kimi-1")
        let second = try await addKimi(c, key: "sk-kimi-2")
        XCTAssertEqual(first.name, "Kimi Code")
        XCTAssertEqual(second.name, "Kimi Code 2", "another subscription doesn't overwrite the first")
        XCTAssertEqual(c.apiKey(for: first), "sk-kimi-1")
        XCTAssertEqual(c.apiKey(for: second), "sk-kimi-2")
        XCTAssertEqual(c.mainRoute?.routeID, first.routeID, "the first one still leads")
    }
}

