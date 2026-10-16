import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The primary stops answering; a backup takes the turn, and the chat says so — once.
@MainActor
final class FailoverHostTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-failover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private func makeTransport(_ routes: [ProviderProfile]) -> AppTransport {
        defaultsSuite = "vision-failover-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.providers = routes
        config.activeRoute = routes.first?.routeID
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        let t = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                             queueFile: dir.appendingPathComponent("task-queue.json"),
                             skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                             vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        t.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        transport = t
        return t
    }

    private func route(_ name: String, host: String, backup: Bool = false, enabled: Bool? = nil) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(host)/v1", model: "stub-model",
                        enabled: enabled, backup: backup ? true : nil)
    }

    private func waitForReply(_ vm: SessionVM, _ reply: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(vm.entries.contains { $0.message?.role == .assistant && $0.message?.text.contains(reply) == true } && !vm.running) {
            if Date() > deadline { return XCTFail("no reply") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func notes(_ vm: SessionVM) -> [String] {
        vm.entries.compactMap { $0.message?.role == .notice ? $0.message?.text : nil }
    }

    func testABackupTakesTheTurnAndTheChatSaysSo() async throws {
        let t = makeTransport([route("Spark", host: "spark.test"), route("Off", host: "off.test", backup: true, enabled: false),
                               route("Kimi Code", host: "kimi.test", backup: true)])
        FakeModelServer.reset { seen, _ in
            seen.host == "spark.test" ? .http(503, "overloaded") : .text("Answered by \(seen.host).")
        }
        let vm = t.newSession(cwd: dir.path)
        t.send("hello", sessionID: vm.id)
        try await waitForReply(vm, "Answered by kimi.test.")
        XCTAssertFalse(FakeModelServer.seen.contains { $0.host == "off.test" }, "a backup that is switched off isn't used")
        XCTAssertEqual(notes(vm).filter { $0.contains("so this turn ran on") },
                       ["Spark didn't answer (HTTP 503: overloaded), so this turn ran on Kimi Code."])
    }

    func testWithoutABackupTheOutageRetryIsUnchanged() async throws {
        let t = makeTransport([route("Spark", host: "spark.test")])
        FakeModelServer.reset { _, index in index == 1 ? .http(503, "overloaded") : .text("Back.") }
        let vm = t.newSession(cwd: dir.path)
        t.send("hello", sessionID: vm.id)
        try await waitForReply(vm, "Back.")
        XCTAssertTrue(notes(vm).contains { $0.hasPrefix("⚠️ The model didn't answer") }, "the usual retry notice")
        XCTAssertFalse(notes(vm).contains { $0.contains("so this turn ran on") })
    }
}
