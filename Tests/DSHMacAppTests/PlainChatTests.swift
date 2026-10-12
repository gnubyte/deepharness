import XCTest
@testable import DSHMacApp
@testable import DSHCore

/// A chat without a project: a regular conversation with a folder of its own, the user's own instructions and
/// skills, and no project's.
@MainActor
final class PlainChatTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!
    private var support: URL { dir.appendingPathComponent("support", isDirectory: true) }

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Hello!") }
        defaultsSuite = "dsh-plain-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model"))
        config.preset = PermissionPreset.workspaceWrite.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: support),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        transport.goalErrorBackoff = { _ in 0.02 }
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

    private func project() -> URL {
        let url = dir.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func skill(_ name: String, in folder: URL) throws {
        let file = folder.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Use for \(name).\n---\n\nDo \(name).".write(to: file, atomically: true, encoding: .utf8)
    }

    private func ask(_ text: String, in vm: SessionVM) async throws {
        let before = vm.entries.filter { $0.message?.role == .assistant }.count
        transport.send(text, sessionID: vm.id)
        let deadline = Date().addingTimeInterval(15)
        while !(vm.entries.filter({ $0.message?.role == .assistant }).count > before && !vm.running) {
            if Date() > deadline { return XCTFail("no reply") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private var lastSystemPrompt: String { FakeModelServer.seen.last?.messages.first { $0["role"] == "system" }?["content"] ?? "" }

    func testAChatWithoutAProjectGetsTheRegularConversationPromptAndItsOwnFolder() async throws {
        try "Call me Pat.".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let vm = transport.newSession(cwd: nil)
        try await ask("hi", in: vm)
        let folder = ChatPrompt.scratchFolder(chatID: vm.id, appSupport: support)
        XCTAssertTrue(lastSystemPrompt.hasPrefix("You are DSH, a helpful assistant in a native macOS app. This is a regular conversation"))
        XCTAssertTrue(lastSystemPrompt.contains("work in this chat's own scratch folder, \(folder.path);"))
        XCTAssertFalse(lastSystemPrompt.contains("working in the user's project folder"))
        XCTAssertTrue(lastSystemPrompt.contains("--- ~/AGENTS.md (the user's own instructions — follow these) ---\nCall me Pat."),
                      "the user's own instruction files, as before")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue, "made on first use")
    }

    func testAChatWithAProjectKeepsTheCodingAgent() async throws {
        let vm = transport.newSession(cwd: project().path)
        try await ask("hi", in: vm)
        XCTAssertTrue(lastSystemPrompt.hasPrefix(AppTransport.defaultSystemPrompt))
        XCTAssertTrue(lastSystemPrompt.contains("Project folder: \(project().path)"))
    }

    func testItsFilesAndCommandsStayInItsFolder() async throws {
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("write_file", #"{"file_path":"notes.txt","content":"draft"}"#) : .text("Saved notes.txt.")
        }
        let vm = transport.newSession(cwd: nil)
        try await ask("draft some notes", in: vm)
        let folder = ChatPrompt.scratchFolder(chatID: vm.id, appSupport: support)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.txt"), encoding: .utf8), "draft",
                       "a relative path lands in the chat's folder, without asking (it is the workspace)")
        XCTAssertTrue(vm.pendingGates.isEmpty)
    }

    func testItsSkillsAreTheUsersOwnNotTheOpenProjects() throws {
        try skill("project-thing", in: project().appendingPathComponent(".dsh/skills"))
        try skill("my-thing", in: support.appendingPathComponent("skills"))
        transport.adoptProject(project())
        let plain = transport.newSession(cwd: nil)
        let coding = transport.newSession(cwd: project().path)
        let plainNames = transport.skills(for: plain).map(\.name)
        XCTAssertTrue(plainNames.contains("my-thing"))
        XCTAssertFalse(plainNames.contains("project-thing"), "no project skills in a chat without a project")
        XCTAssertTrue(transport.skills(for: coding).map(\.name).contains("project-thing"))
    }

    func testDeletingTheChatDeletesItsFolder() async throws {
        let vm = transport.newSession(cwd: nil)
        try await ask("hi", in: vm)
        let folder = ChatPrompt.scratchFolder(chatID: vm.id, appSupport: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        transport.deleteSession(vm.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAQueueTaskFromTheChatWorksInTheChatsFolder() async throws {
        transport.adoptProject(project())   // a project is open, but the task belongs to the plain chat
        FakeModelServer.reset { seen, _ in
            if seen.lastUser == "queue it", seen.fresh {
                return .toolCall("queue_task", #"{"title":"Write the letter","details":"to Ann"}"#)
            }
            if seen.lastUser.contains("GOAL: Write the letter"), seen.fresh {
                return .toolCall("write_file", #"{"file_path":"letter.txt","content":"Dear Ann"}"#)
            }
            return .text("Done.\nGOAL_COMPLETE")
        }
        let vm = transport.newSession(cwd: nil)
        try await ask("queue it", in: vm)
        let folder = ChatPrompt.scratchFolder(chatID: vm.id, appSupport: support)
        let task = try XCTUnwrap(transport.queue.tasks.first)
        XCTAssertNil(task.cwd)
        XCTAssertEqual(task.workFolder, folder.path)

        transport.startQueue()
        let deadline = Date().addingTimeInterval(15)
        while transport.queueRunning {
            if Date() > deadline { return XCTFail("the queue never finished") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.queue.task(task.id)?.status, .complete)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("letter.txt"), encoding: .utf8), "Dear Ann")
        let taskChat = try XCTUnwrap(transport.sessions.first { $0.id == transport.queue.task(task.id)?.sessionID })
        XCTAssertTrue(taskChat.isPlain)
        XCTAssertEqual(taskChat.workFolder, folder.path)
    }

    func testAFolderLentToAQueuedTaskOutlivesItsChatUntilTheTaskIsDone() async throws {
        FakeModelServer.reset { seen, _ in
            if seen.lastUser.contains("GOAL: Write the letter"), seen.fresh {
                return .toolCall("write_file", #"{"file_path":"letter.txt","content":"Dear Ann"}"#)
            }
            return .text("Done.\nGOAL_COMPLETE")
        }
        let vm = transport.newSession(cwd: nil)
        let folder = transport.scratchFolder(for: vm, create: true)
        let task = transport.queueAdd("Write the letter")
        XCTAssertEqual(task.workFolder, folder.path)

        transport.deleteSession(vm.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the queued task still works there")

        transport.startQueue()
        let deadline = Date().addingTimeInterval(15)
        while transport.queueRunning {
            if Date() > deadline { return XCTFail("the queue never finished") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.queue.task(task.id)?.status, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "its chat is gone and its last task is done")
    }

    func testAFolderStaysWhileItsChatDoes() async throws {
        FakeModelServer.reset { _, _ in .text("Done.\nGOAL_COMPLETE") }
        let vm = transport.newSession(cwd: nil)
        let folder = transport.scratchFolder(for: vm, create: true)
        let task = transport.queueAdd("Tidy up")
        transport.startQueue()
        let deadline = Date().addingTimeInterval(15)
        while transport.queueRunning {
            if Date() > deadline { return XCTFail("the queue never finished") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.queue.task(task.id)?.status, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the chat that owns it is still here")
        // Removing a task never reaches outside the app's own Chats folder.
        let outside = dir.appendingPathComponent("not-a-chat", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        transport.releaseBorrowedFolder(outside.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

