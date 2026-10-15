import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// A chat with a model that isn't private: the server sees placeholders, the chat shows the real values and a chip
/// saying what was masked.
@MainActor
final class ShieldHostTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-shield-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        ProviderClients.shield = ShieldPolicy()
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        ProviderClients.shield = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
        try await super.tearDown()
    }

    private func makeTransport(_ route: ProviderProfile) -> AppTransport {
        defaultsSuite = "vision-shield-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.providers = [route]
        config.activeRoute = route.routeID
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

    private func waitForReply(_ vm: SessionVM) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(vm.entries.contains { $0.message?.role == .assistant } && !vm.running) {
            if Date() > deadline { return XCTFail("no reply") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAnOnlineModelSeesPlaceholdersAndTheChatShowsWhatWasMasked() async throws {
        let t = makeTransport(ProviderProfile(kind: .openAICompat, name: "Kimi Code", baseURL: "https://kimi.test/v1", model: "stub-model"))
        FakeModelServer.reset { seen, _ in .text("I'll write to \(seen.lastUser.components(separatedBy: " ").last ?? "").") }
        let vm = t.newSession(cwd: dir.path)
        t.send("Please email ann@example.com", sessionID: vm.id)
        try await waitForReply(vm)

        let sent = try XCTUnwrap(FakeModelServer.seen.first)
        XCTAssertEqual(sent.lastUser, "Please email ⟦EMAIL_1⟧")
        XCTAssertFalse(sent.messages.contains { ($0["content"] ?? "").contains("ann@example.com") }, "the address never left")
        XCTAssertTrue(sent.messages.first?["content"]?.hasSuffix(Shield.note) == true, "the note ends the system prompt")
        let answer = try XCTUnwrap(vm.entries.first { $0.message?.role == .assistant })
        XCTAssertEqual(answer.message?.text, "I'll write to ann@example.com.", "the chat shows the real value")
        XCTAssertEqual(vm.masked[answer.id]?.summary, "Masked 1 email before sending to Kimi Code")
    }

    func testAPrivateModelGetsEverythingAsItIs() async throws {
        let t = makeTransport(ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8002/v1", model: "stub-model"))
        FakeModelServer.reset { _, _ in .text("ok") }
        let vm = t.newSession(cwd: dir.path)
        t.send("Please email ann@example.com", sessionID: vm.id)
        try await waitForReply(vm)
        XCTAssertEqual(FakeModelServer.seen.first?.lastUser, "Please email ann@example.com")
        XCTAssertTrue(vm.masked.isEmpty)
    }

    func testPicturesAndFilesThatArentTextGetAOneTimeWord() async throws {
        let t = makeTransport(ProviderProfile(kind: .openAICompat, name: "Kimi Code", baseURL: "https://kimi.test/v1", model: "stub-model"))
        FakeModelServer.reset { _, _ in .text("ok") }
        let vm = t.newSession(cwd: dir.path)
        let pdf = MessageAttachment(kind: .file, name: "contract.pdf", data: Data("%PDF-1.7 ann@example.com".utf8))
        let picture = MessageAttachment(kind: .image, name: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        t.send("read this", sessionID: vm.id, attachments: [pdf])
        try await waitForReply(vm)
        t.send("and look", sessionID: vm.id, attachments: [picture])
        let deadline = Date().addingTimeInterval(15)
        while FakeModelServer.seen.count < 2 || vm.running {
            if Date() > deadline { return XCTFail("no second reply") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let notices = vm.entries.compactMap { $0.message?.role == .notice ? $0.message?.text : nil }
        XCTAssertEqual(notices.filter { $0.hasPrefix("Pictures and files") },
                       ["Pictures and files that aren't plain text are sent as they are — DSH can't check them for sensitive details."],
                       "once per chat, for a PDF as for a picture")
    }
}
