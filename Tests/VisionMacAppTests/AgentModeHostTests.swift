import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// Per-chat folders, Agent mode, worktree chats and the archive, through the
/// real transport and engine against a fake model server.
@MainActor
final class AgentModeHostTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: realpath(scratch.path, nil).map { String(cString: $0) } ?? scratch.path, isDirectory: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        suite = "dsh-agent-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: suite)!)
        let route = ProviderProfile(kind: .openAICompat, name: "Main", baseURL: "http://main.test/v1", model: "stub-model")
        config.providers = [route]
        config.activeRoute = route.routeID
        config.preset = PermissionPreset.workspaceWrite.rawValue
        config.computerToolsEnabled = false
        config.gitAutoSync = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private func folder(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Send, and wait for the turn to finish with the marker word.
    private func send(_ text: String, in vm: SessionVM, until reply: String = "Finished.") async throws {
        let before = vm.entries.filter { $0.message?.role == .assistant && $0.message?.text.contains(reply) == true }.count
        transport.send(text, sessionID: vm.id)
        let deadline = Date().addingTimeInterval(20)
        while vm.running || vm.entries.filter({ $0.message?.role == .assistant && $0.message?.text.contains(reply) == true }).count == before {
            if Date() > deadline { XCTFail("timed out; gates: \(vm.pendingGates) running: \(vm.running) tools: \(vm.entries.compactMap(\.tool).map { "\($0.name) ok=\(String(describing: $0.isOk)) \($0.output ?? "")" }) texts: \(vm.entries.compactMap { $0.message?.text })"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func agentThread() -> SessionVM {
        let vm = transport.newSession(cwd: folder("agent-home").path)
        vm.isAgent = true
        transport.log.updateMeta(vm.id) { $0.kind = "agent" }
        return vm
    }

    private func toolOutput(_ name: String, in vm: SessionVM) -> String? {
        vm.entries.compactMap(\.tool).first { $0.name == name }?.output
    }

    private func systemPrompt(of seen: SeenRequest) -> String {
        seen.messages.first { $0["role"] == "system" }?["content"] ?? ""
    }

    // MARK: Folders

    func testAFolderAddedToOneChatReachesThatChatOnly() async throws {
        let extra = folder("beta")
        try "THE-BETA-RULE".write(to: extra.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        FakeModelServer.reset { _, _ in .text("Finished.") }

        let with = transport.newSession(cwd: folder("alpha").path)
        let without = transport.newSession(cwd: folder("alpha").path)
        transport.addFolders([extra], to: with)

        try await send("one", in: with)
        XCTAssertTrue(systemPrompt(of: FakeModelServer.seen.last!).contains("THE-BETA-RULE"))
        try await send("two", in: without)
        XCTAssertFalse(systemPrompt(of: FakeModelServer.seen.last!).contains("THE-BETA-RULE"))
    }

    func testTheAddedFolderIsInsideThatChatsPermissionBoundary() async throws {
        let extra = folder("beta")
        let target = extra.appendingPathComponent("made.txt").path
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("write_file", #"{"file_path":"\#(target)","content":"hi"}"#) : .text("Finished.")
        }
        let vm = transport.newSession(cwd: folder("alpha").path)
        transport.addFolders([extra], to: vm)
        try await send("write", in: vm)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target), "\(vm.entries.map(\.kind))")
    }

    func testRemovingAFolderTakesEffectOnTheNextTurnAndSurvivesAReload() async throws {
        let extra = folder("beta")
        try "THE-BETA-RULE".write(to: extra.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        FakeModelServer.reset { _, _ in .text("Finished.") }
        let vm = transport.newSession(cwd: folder("alpha").path)
        transport.addFolders([extra], to: vm)
        XCTAssertEqual(transport.log.session(vm.id)?.additionalFolders, [extra.path])
        try await send("one", in: vm)
        transport.removeFolder(extra.path, from: vm)
        try await send("two", in: vm)
        XCTAssertFalse(systemPrompt(of: FakeModelServer.seen.last!).contains("THE-BETA-RULE"))
        XCTAssertEqual(transport.log.session(vm.id)?.additionalFolders, [])
    }

    // MARK: Agent mode

    func testAnAgentThreadGetsTheAgentPromptAndAnOrdinaryChatDoesnt() async throws {
        FakeModelServer.reset { _, _ in .text("Finished.") }
        try await send("hi", in: agentThread())
        XCTAssertTrue(systemPrompt(of: FakeModelServer.seen.last!).contains("--- Agent mode ---"))
        try await send("hi", in: transport.newSession(cwd: folder("alpha").path))
        XCTAssertFalse(systemPrompt(of: FakeModelServer.seen.last!).contains("--- Agent mode ---"))
    }

    private nonisolated static let skillCall = #"{"name":"weekly-sweep","description":"Use for the weekly sweep","instructions":"1. Do the sweep carefully, in order.\n2. Report."}"#

    func testTheAgentsSkillGoesLiveAndIsInTheNextPrompt() async throws {
        FakeModelServer.reset { seen, _ in
            seen.fresh && seen.lastUser == "save it" ? .toolCall("create_skill", Self.skillCall) : .text("Finished.")
        }
        let vm = agentThread()
        try await send("save it", in: vm)
        let file = dir.appendingPathComponent("support/skills/weekly-sweep/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), toolOutput("create_skill", in: vm) ?? "no call")
        try await send("next", in: vm)
        XCTAssertTrue(systemPrompt(of: FakeModelServer.seen.last!).contains("weekly-sweep"))
    }

    func testWithTheSettingOffTheAgentCantSaveASkillDirectly() async throws {
        transport.config.agentSavesSkills = false
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("create_skill", Self.skillCall) : .text("Finished.")
        }
        try await send("save it", in: agentThread())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("support/skills/weekly-sweep").path))
    }

    func testAnOrdinaryChatCantSaveASkillDirectly() async throws {
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("create_skill", Self.skillCall) : .text("Finished.")
        }
        try await send("save it", in: transport.newSession(cwd: folder("alpha").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("support/skills/weekly-sweep").path))
    }

    func testALongTurnNudgesTheNextOneWithoutShowingInTheChat() async throws {
        let target = folder("agent-home").appendingPathComponent("x.txt").path
        let call = #"{"file_path":"\#(target)","content":"x"}"#
        FakeModelServer.reset { seen, index in
            seen.lastUser == "long" && index <= 6 ? .toolCall("write_file", call) : .text("Finished.")
        }
        let vm = agentThread()
        try await send("long", in: vm)
        try await send("after", in: vm)
        XCTAssertTrue(FakeModelServer.seen.last?.lastUser.contains("Harness note") == true)
        XCTAssertFalse(vm.entries.contains { $0.message?.text.contains("Harness note") == true })
        try await send("later", in: vm)
        XCTAssertEqual(FakeModelServer.seen.last?.lastUser, "later", "only the one turn after")
    }

    func testTheAgentCanScheduleWork() async throws {
        let added = Box<[Automation]>([])
        transport.scheduleFromAgent = { added.value.append($0) }
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("schedule_task", #"{"name":"Check build","prompt":"Check the build","cron":"0 9 * * 1"}"#) : .text("Finished.")
        }
        let vm = agentThread()
        try await send("remind me", in: vm)
        XCTAssertEqual(added.value.map(\.name), ["Check build"], toolOutput("schedule_task", in: vm) ?? "no call")
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: Worktrees and the archive

    private func repo() throws -> URL {
        let url = folder("app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "git init -q -b main && git -c user.email=t@e.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m first"]
        process.currentDirectoryURL = url
        try process.run()
        process.waitUntilExit()
        return url
    }

    func testAWorktreeChatWorksInItsFolderAndFilesUnderItsProject() async throws {
        let project = try repo()
        let vm = try await transport.newWorktreeSession(project: project, title: "Add Search")
        XCTAssertEqual(vm.cwd, dir.appendingPathComponent("app-worktrees/add-search").path)
        XCTAssertEqual(vm.projectPath, project.path)
        XCTAssertEqual(vm.projectName, "app")
        XCTAssertEqual(vm.title, "Add Search")
        XCTAssertEqual(transport.log.session(vm.id)?.worktree?.branch, "dsh/add-search")
    }

    func testArchivingFinishedWorkKeepsTheChatAndRestoringBringsItBack() async throws {
        FakeModelServer.reset { _, _ in .text("Finished.") }
        let vm = transport.newSession(cwd: folder("alpha").path)
        try await send("remember this", in: vm)
        let id = vm.id
        transport.archiveSession(id, reason: "Done")
        XCTAssertFalse(transport.sessions.contains { $0.id == id })
        XCTAssertEqual(transport.archive.chats.first?.id, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("support/archive/\(id).md").path))

        transport.restoreArchived(id)
        let back = try XCTUnwrap(transport.sessions.first { $0.id == id })
        XCTAssertTrue(back.entries.contains { $0.message?.text == "remember this" })
        XCTAssertTrue(transport.archive.chats.isEmpty)
    }

    func testArchivingARunningChatIsRefused() async throws {
        let vm = transport.newSession(cwd: folder("alpha").path)
        vm.running = true
        transport.archiveSession(vm.id, reason: "x")
        XCTAssertTrue(transport.sessions.contains { $0.id == vm.id })
        vm.running = false
    }

    func testAChatOnlyRouteCantBeASubagentWorker() {
        let local = ProviderProfile(kind: .guardian, name: "Orbital", baseURL: "https://g.test/api/harness/v1",
                                    model: "local:n1:qwen", subagentWorker: true)
        transport.config.providers.append(local)
        XCTAssertFalse(transport.config.workerRoutes.contains { $0.isGuardianChatOnly })
    }
}
