import XCTest
@testable import DSHMacApp
@testable import DSHCore

/// A plan whose terms allow only interactive use (the Qwen Coding Plan) never works unattended.
@MainActor
final class InteractiveOnlyTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-interactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Done.\nGOAL_COMPLETE") }
        defaultsSuite = "dsh-interactive-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.providers = [
            ProviderProfile(kind: .openAICompat, name: "Qwen Coding Plan", baseURL: "http://plan.test/v1", model: "stub-model",
                            interactiveOnly: true),
            ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.test/v1", model: "stub-model"),
        ]
        config.activeRoute = config.providers[0].routeID
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.05 })
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
        try await super.tearDown()
    }

    private let refusal = "Qwen Coding Plan is for interactive use only under its plan's terms, so the queue won't run on it. Make another model primary for unattended work."

    func testTheQueueWontStartOnIt() {
        transport.queueAdd("Task A")
        transport.startQueue()
        XCTAssertFalse(transport.queueRunning)
        XCTAssertEqual(transport.banner, refusal)
        XCTAssertTrue(FakeModelServer.seen.isEmpty, "nothing was sent")
    }

    func testAGoalWontStartOnItButAnInteractiveChatDoes() async throws {
        let vm = transport.newSession(cwd: dir.path)
        transport.send("/goal build the thing", sessionID: vm.id)
        XCTAssertTrue(vm.entries.contains { $0.message?.text.hasPrefix("Qwen Coding Plan is for interactive use only") == true })
        XCTAssertTrue(FakeModelServer.seen.isEmpty)

        transport.send("hello", sessionID: vm.id)
        let deadline = Date().addingTimeInterval(10)
        while !vm.entries.contains(where: { $0.message?.role == .assistant }) {
            if Date() > deadline { return XCTFail("the chat never answered") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(FakeModelServer.seen.count, 1, "a chat with you is interactive")
    }

    func testWithAnotherPrimaryTheQueueRuns() async throws {
        transport.config.makeMain(transport.config.providers[1].routeID)
        let task = transport.queueAdd("Task A")
        transport.startQueue()
        XCTAssertTrue(transport.queueRunning)
        let deadline = Date().addingTimeInterval(15)
        while transport.queueRunning {
            if Date() > deadline { return XCTFail("the queue never finished") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.queue.task(task.id)?.status, .complete)
    }
}
