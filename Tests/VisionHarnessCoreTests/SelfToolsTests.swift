import XCTest
@testable import VisionHarnessCore

// MARK: - Prompt history (the durable ledger)

final class PromptHistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prompt-history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("prompt-history.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func store() -> PromptHistoryStore {
        PromptHistoryStore(fileURL: file)
    }

    func testAddAndSearchAcrossModes() {
        let history = store()
        history.add(.init(chatID: "a", chatTitle: "Ticket sweep", mode: .agent, text: "run the ticket sync"))
        history.add(.init(chatID: "b", chatTitle: "Code", mode: .code, text: "fix the parser"))
        history.add(.init(chatID: "c", chatTitle: "Chat", mode: .chat, text: "what does scope mean?"))
        history.add(.init(chatID: "d", chatTitle: "⏰ nightly", mode: .automation, text: "check the build"))

        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.search(query: "ticket").count, 1)
        XCTAssertEqual(history.search(query: "", mode: .automation).first?.text, "check the build")
        // Newest first.
        XCTAssertEqual(history.search(query: "").first?.chatID, "d")
        // Every word must match.
        XCTAssertEqual(history.search(query: "the sync").count, 1)
        XCTAssertEqual(history.search(query: "the parser").count, 1)
        XCTAssertTrue(history.search(query: "zzz").isEmpty)
    }

    func testFinishStampsOutcomeDurationAndArtifacts() {
        let history = store()
        let record = history.add(.init(chatID: "a", chatTitle: "T", mode: .code, text: "fix it", turnID: "turn-1"))
        history.finish(turnID: "turn-1", outcome: .completed(evidence: 3), duration: 42,
                       changedFiles: ["Engine.swift"], model: "glm-5.3")
        let stamped = history.record(withID: record.id)
        if case .completed(let evidence)? = stamped?.outcome {
            XCTAssertEqual(evidence, 3)
        } else {
            XCTFail("outcome should be completed: \(String(describing: stamped?.outcome))")
        }
        XCTAssertEqual(stamped?.duration, 42)
        XCTAssertEqual(stamped?.changedFiles, ["Engine.swift"])
        XCTAssertEqual(stamped?.model, "glm-5.3")
        // Unknown turn ids are ignored.
        history.finish(turnID: "nope", outcome: .stopped, duration: 1)
        XCTAssertEqual(history.count, 1)
    }

    func testFinishRecordByID() {
        let history = store()
        let record = history.add(.init(chatID: "a", chatTitle: "T", mode: .automation, text: "nightly"))
        history.finishRecord(id: record.id, outcome: .failed(reason: "the model was down"), duration: 90.5,
                             changedFiles: [])
        if case .failed(let reason)? = history.record(withID: record.id)?.outcome {
            XCTAssertEqual(reason, "the model was down")
        } else {
            XCTFail("expected failed")
        }
        XCTAssertEqual(history.record(withID: record.id)?.duration, 90.5)
    }

    func testRetitleFollowsRenames() {
        let history = store()
        history.add(.init(chatID: "a", chatTitle: "New chat", mode: .chat, text: "hello"))
        history.add(.init(chatID: "a", chatTitle: "New chat", mode: .chat, text: "again"))
        history.retitle(chatID: "a", title: "Parser work")
        XCTAssertTrue(history.all.allSatisfy { $0.chatTitle == "Parser work" })
    }

    func testPersistsAndReloads() {
        do {
            let history = store()
            history.add(.init(chatID: "a", chatTitle: "T", mode: .chat, text: "hello", turnID: "t1"))
            history.finish(turnID: "t1", outcome: .stopped, duration: 12)
        }
        // The write lands off-thread; a new store over the same file reads it.
        var reloadedCount = 0
        for _ in 0..<40 {
            reloadedCount = store().count
            if reloadedCount == 1 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(reloadedCount, 1)
        XCTAssertEqual(reloaded.all.first?.text, "hello")
        if case .stopped? = reloaded.all.first?.outcome {} else {
            XCTFail("outcome did not survive the round-trip")
        }
        XCTAssertEqual(reloaded.all.first?.duration, 12)
    }

    func testOutcomeCodableRoundTrip() throws {
        let outcomes: [PromptHistoryRecord.Outcome] = [
            .working, .completed(evidence: 4), .blocked(reason: "needs a key"),
            .failed(reason: "timeout"), .stopped,
        ]
        let data = try JSONEncoder().encode(outcomes)
        let decoded = try JSONDecoder().decode([PromptHistoryRecord.Outcome].self, from: data)
        XCTAssertEqual(decoded.count, outcomes.count)
        for (a, b) in zip(outcomes, decoded) {
            XCTAssertEqual(a.label, b.label)
            if case .completed(let e) = a, case .completed(let e2) = b { XCTAssertEqual(e, e2) }
            if case .blocked(let r) = a, case .blocked(let r2) = b { XCTAssertEqual(r, r2) }
        }
    }

    func testCapacityDropsOldest() {
        let history = PromptHistoryStore(fileURL: nil, capacity: 5)
        for i in 0..<12 {
            history.add(.init(chatID: "c", chatTitle: "T", mode: .chat, text: "prompt \(i)"))
        }
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.all.first?.text, "prompt 7")
    }
}

// MARK: - Self tools (the harness managing itself)

final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.withLock { n } }
}

final class SelfToolsTests: XCTestCase {
    private var dir: URL!
    private var vault: CredentialVault!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("self-tools-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        vault = CredentialVault(directory: dir, store: MemoryBlobStore())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private final class NullClient: LLMClient, @unchecked Sendable {
        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func listModels() async throws -> [String] { [] }
    }

    private var context: ToolContext {
        ToolContext(workspace: dir, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: dir),
                    client: NullClient(), registry: ToolRegistry.standard())
    }

    func testVaultAddUpdateDeleteLifecycle() async {
        let changed = ChangeCounter()
        let add = VaultAddTool(vault: vault, onChange: { changed.bump() })
        let result = await add.execute(args: """
            {"name":"TEST_API_KEY","value":"sk-supersecret","kind":"apiKey",
             "description":"for tests","tags":["test"],"access":"allowed"}
            """, in: context)
        XCTAssertTrue(result.output.contains("Stored"), result.output)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(vault.entry(named: "test_api_key")?.placeholder
                           .contains("TEST_API_KEY"), true)

        // Duplicate name refused.
        let dup = await add.execute(args: #"{"name":"TEST_API_KEY","value":"x"}"#, in: context)
        XCTAssertTrue(dup.output.contains("Error:"), dup.output)

        let update = VaultUpdateTool(vault: vault, onChange: { changed.bump() })
        let updated = await update.execute(args: """
            {"name":"TEST_API_KEY","description":"rotated","access":"ask"}
            """, in: context)
        XCTAssertTrue(updated.output.contains("Updated"), updated.output)
        XCTAssertEqual(changed.count, 2)
        XCTAssertEqual(vault.entry(named: "TEST_API_KEY")?.access, .ask)
        XCTAssertEqual(vault.entry(named: "TEST_API_KEY")?.description, "rotated")

        let delete = VaultDeleteTool(vault: vault, onChange: { changed.bump() })
        let deleted = await delete.execute(args: #"{"name":"TEST_API_KEY"}"#, in: context)
        XCTAssertTrue(deleted.output.contains("Deleted"), deleted.output)
        XCTAssertEqual(changed.count, 3)
        XCTAssertTrue(vault.all.isEmpty)

        let missing = await delete.execute(args: #"{"name":"NOPE"}"#, in: context)
        XCTAssertTrue(missing.output.contains("Error:"), missing.output)
    }

    func testVaultUpdateRotatesValue() async {
        _ = try? vault.add(name: "ROTATE_ME", value: "old-value")
        let update = VaultUpdateTool(vault: vault)
        _ = await update.execute(args: #"{"name":"ROTATE_ME","value":"new-value"}"#, in: context)
        if case .value(let value, _) = vault.lookup("ROTATE_ME") {
            XCTAssertEqual(value, "new-value")
        } else {
            XCTFail("rotation did not land")
        }
    }

    func testAutomationRunTool() async {
        struct Called { var id = false; var byName = false }
        let called = Called()
        let tool = AutomationRunTool { id, name in
            if id == "abc" { return true }
            if name == "nightly" { return true }
            return false
        }
        _ = called
        let ok = await tool.execute(args: #"{"id":"abc"}"#, in: context)
        XCTAssertTrue(ok.output.contains("Running"))
        let okByName = await tool.execute(args: #"{"name":"nightly"}"#, in: context)
        XCTAssertTrue(okByName.output.contains("Running"))
        let miss = await tool.execute(args: #"{"name":"nope"}"#, in: context)
        XCTAssertTrue(miss.output.contains("Error:"))
        let empty = await tool.execute(args: #"{}"#, in: context)
        XCTAssertTrue(empty.output.contains("Error:"))
    }

    func testSearchChatsFindsAcrossTranscripts() async {
        // Two conversation files in the shape ConversationLog writes.
        let conversations = dir.appendingPathComponent("conversations")
        try? FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let chat: [String: Any] = [
            "session": ["id": "chat-1", "title": "Parser work"],
            "items": [["seq": 0, "kind": "user", "text": "How does the scopeScale estimator work?", "at": Date()]],
        ]
        let agent: [String: Any] = [
            "session": ["id": "chat-2", "title": "Agent"],
            "items": [["seq": 0, "kind": "assistant", "text": "The scopeScale blends words, steps and project files.", "at": Date()]],
        ]
        for (name, object) in [("chat-1.json", chat), ("chat-2.json", agent)] {
            let data = try! JSONSerialization.data(withJSONObject: object)
            try? data.write(to: conversations.appendingPathComponent(name))
        }
        let tool = SearchChatsTool(directory: conversations)
        let hit = await tool.execute(args: #"{"query":"scopeScale estimator"}"#, in: context)
        XCTAssertTrue(hit.output.contains("Parser work"), hit.output)
        XCTAssertTrue(hit.output.contains("scopeScale"), hit.output)
        let miss = await tool.execute(args: #"{"query":"zebra-unicorn"}"#, in: context)
        XCTAssertTrue(miss.output.contains("No chat mentions"), miss.output)
    }

    func testHarnessInfoReportsStores() async {
        _ = try? vault.add(name: "INFO_KEY", value: "v")
        let memory = HarnessMemory(appSupport: dir.appendingPathComponent("support"))
        try? memory.setUp()
        let history = PromptHistoryStore(fileURL: nil)
        history.add(.init(chatID: "a", chatTitle: "T", mode: .chat, text: "hello"))
        let tool = HarnessInfoTool(memory: memory, vault: vault, promptHistory: history) { [] }
        let result = await tool.execute(args: "{}", in: context)
        XCTAssertTrue(result.output.contains("credential"), result.output)
        XCTAssertTrue(result.output.contains("1 record"), result.output)
        XCTAssertTrue(result.output.contains("MEMORY.md"), result.output)
    }

    func testImportMemoryToolImportsAndDedupes() async {
        let source = dir.appendingPathComponent("openclaw-memory")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? "# Memory\n\n- The user prefers PST\n- Deploy on Tuesdays\n".write(
            to: source.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try? "# 2026-01-04\n\n- Something from that day\n".write(
            to: source.appendingPathComponent("2026-01-04.md"), atomically: true, encoding: .utf8)

        let memory = HarnessMemory(appSupport: dir.appendingPathComponent("support"))
        let tool = ImportMemoryTool(memory: memory)
        let first = await tool.execute(args: JSONString("{\"path\":\"\(source.path)\"}"), in: context)
        XCTAssertTrue(first.output.contains("3 new lines"), first.output)

        // Idempotent: importing again adds nothing.
        let second = await tool.execute(args: JSONString("{\"path\":\"\(source.path)\"}"), in: context)
        XCTAssertTrue(second.output.contains("0 new lines"), second.output)

        // The durable file holds the non-dated lines.
        let durable = memory.durable()
        XCTAssertTrue(durable.contains("The user prefers PST"))
        XCTAssertTrue(durable.contains("Deploy on Tuesdays"))
        // The dated line kept its own day.
        let dated = (try? String(contentsOf: memory.memoryDirectory.appendingPathComponent("2026-01-04.md"))) ?? ""
        XCTAssertTrue(dated.contains("Something from that day"))
        XCTAssertTrue(!durable.contains("Something from that day"), "dated lines stay in their day's log")
    }

    func testImportMemoryToolMissingPath() async {
        let memory = HarnessMemory(appSupport: dir.appendingPathComponent("support"))
        let tool = ImportMemoryTool(memory: memory)
        let result = await tool.execute(args: #"{"path":"/nonexistent/nowhere"}"#, in: context)
        XCTAssertTrue(result.output.contains("Error:"), result.output)
    }
}
