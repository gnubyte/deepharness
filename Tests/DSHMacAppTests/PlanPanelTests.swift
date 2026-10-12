import XCTest
@testable import DSHMacApp
@testable import DSHCore

/// What the plan panel shows comes from the chat: its steps, a proposed plan — and it opens by itself the first time
/// the selected chat's agent makes one.
@MainActor
final class PlanPanelTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        defaultsSuite = "dsh-plan-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model"))
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
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

    private static let todos = #"{"todos":[{"content":"Read the code","status":"completed"},{"content":"Fix the bug","status":"in_progress"},{"content":"Test it","status":"pending"}]}"#

    /// The model makes a tool call on the first request of each turn, then answers.
    private func script(_ tool: String, _ args: String) {
        FakeModelServer.reset { seen, _ in seen.fresh ? .toolCall(tool, args) : .text("Done.") }
    }

    private func run(_ text: String, in vm: SessionVM) async throws {
        transport.send(text, sessionID: vm.id)
        let deadline = Date().addingTimeInterval(15)
        while !(vm.entries.contains { $0.message?.role == .assistant } && !vm.running) {
            if Date() > deadline { return XCTFail("no reply") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testTheFirstPlanOpensThePanelForTheSelectedChat() async throws {
        script("todo_write", Self.todos)
        let vm = transport.newSession(cwd: dir.path)
        XCTAssertFalse(vm.hasPlan)
        XCTAssertFalse(transport.config.planPanelOpen)
        try await run("fix it", in: vm)
        XCTAssertEqual(vm.todos.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertTrue(vm.hasPlan)
        XCTAssertTrue(transport.config.planPanelOpen, "the panel opened by itself")

        // Closed by the user, it stays closed for this chat's later plans.
        transport.config.planPanelOpen = false
        vm.entries.removeAll()
        try await run("again", in: vm)
        XCTAssertFalse(transport.config.planPanelOpen)
    }

    func testItDoesNotOpenWhenTheUserSaidNo() async throws {
        transport.config.planPanelAutoOpen = false
        script("todo_write", Self.todos)
        let vm = transport.newSession(cwd: dir.path)
        try await run("fix it", in: vm)
        XCTAssertFalse(vm.todos.isEmpty)
        XCTAssertFalse(transport.config.planPanelOpen)
    }

    func testAChatThatIsNotSelectedDoesNotOpenIt() async throws {
        script("todo_write", Self.todos)
        let background = transport.newSession(cwd: dir.path, select: false)
        _ = transport.newSession(cwd: dir.path)          // the one the user is looking at
        try await run("fix it", in: background)
        XCTAssertFalse(background.todos.isEmpty)
        XCTAssertFalse(transport.config.planPanelOpen)
    }

    func testAProposedPlanIsKeptWithItsChat() async throws {
        script("exit_plan_mode", #"{"plan":"1. Read the code\n2. Change **one** line"}"#)
        let vm = transport.newSession(cwd: dir.path)
        let other = transport.newSession(cwd: dir.path, select: false)
        transport.selectedID = vm.id
        try await run("plan it", in: vm)
        XCTAssertEqual(vm.proposedPlan, "1. Read the code\n2. Change **one** line")
        XCTAssertNil(other.proposedPlan, "plans are per chat")
        XCTAssertTrue(transport.config.planPanelOpen)
    }

    func testThePanelSettingsAreRemembered() {
        transport.config.planPanelOpen = true
        transport.config.planPanelWidth = 410
        transport.config.planPanelAutoOpen = false
        let again = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        XCTAssertTrue(again.planPanelOpen)
        XCTAssertEqual(again.planPanelWidth, 410)
        XCTAssertFalse(again.planPanelAutoOpen)
    }
}
