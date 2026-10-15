import XCTest
@testable import VisionHarnessCore

/// A chat without a project is a regular conversation: its own prompt, its own scratch folder.
final class ChatPromptTests: XCTestCase {
    private let scratch = URL(fileURLWithPath: "/Users/pat/Library/Application Support/DSHMac/Chats/ABC-123", isDirectory: true)

    func testWithoutAProjectTheChatIsARegularConversation() {
        XCTAssertEqual(ChatPrompt.kind(project: nil), .plain)
        XCTAssertEqual(ChatPrompt.kind(project: URL(fileURLWithPath: "/code/app")), .coding)
    }

    func testThePlainPromptSaysSoInTheSpecsWords() {
        XCTAssertEqual(ChatPrompt.plain(scratch: scratch),
                       "You are DSH, a helpful assistant in a native macOS app. This is a regular conversation: no project folder is open and none is needed — never ask the user to open one. Answer directly and naturally; match the length of your answer to the question. Use tools only when they help: look things up with web_fetch, use one of the user's skills when it fits the request, and remember lasting preferences with memory. When something needs files or commands — a skill that runs a script, a document to draft, data to convert — work in this chat's own scratch folder, /Users/pat/Library/Application Support/DSHMac/Chats/ABC-123; it belongs to this chat and starts empty. Tell the user where a file you made is when it matters.")
    }

    func testTheBasePromptIsChosenByWhetherThereIsAProject() {
        let coding = "You are a capable coding agent…"
        XCTAssertEqual(ChatPrompt.base(project: URL(fileURLWithPath: "/code/app"), scratch: scratch, codingPrompt: coding), coding)
        let plain = ChatPrompt.base(project: nil, scratch: scratch, codingPrompt: coding)
        XCTAssertTrue(plain.hasPrefix("You are DSH, a helpful assistant in a native macOS app."))
        XCTAssertTrue(plain.hasSuffix(ChatPrompt.macMemory))
        XCTAssertFalse(plain.contains("project folder is open and needed"))
        XCTAssertFalse(plain.contains(coding))
    }

    func testTheScratchFolderLivesUnderTheAppsDataFolder() {
        let support = URL(fileURLWithPath: "/Users/pat/Library/Application Support/DSHMac", isDirectory: true)
        XCTAssertEqual(ChatPrompt.scratchFolder(chatID: "ABC-123", appSupport: support).path, scratch.path)
    }

    func testThePlainEnvironmentNamesTheChatFolderNotAProject() {
        let block = ChatPrompt.environment(scratch: scratch, model: "qwen", preset: .workspaceWrite)
        XCTAssertTrue(block.contains("Chat folder (scratch): \(scratch.path)"))
        XCTAssertFalse(block.contains("Project folder"))
        XCTAssertFalse(block.contains("Git branch"))
    }

    func testTheUsersOwnInstructionsAreLabelledAsTheirs() {
        let files = [InstructionFile(url: URL(fileURLWithPath: "/Users/pat/AGENTS.md"), text: "Be brief.\n", label: "AGENTS.md")]
        XCTAssertEqual(ChatPrompt.userInstructions(files), "--- ~/AGENTS.md (the user's own instructions — follow these) ---\nBe brief.")
        XCTAssertNil(ChatPrompt.userInstructions([]))
    }

    func testAQueueTaskFromAChatWithoutAProjectKeepsItsFolder() throws {
        var queue = TaskQueue()
        let task = queue.add("Draft the letter", workFolder: scratch.path)
        XCTAssertNil(task.cwd)
        XCTAssertEqual(task.workFolder, scratch.path)
        let round = try JSONDecoder().decode(TaskQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(round.tasks.first?.workFolder, scratch.path)
        // A project wins; an older file has no folder.
        XCTAssertNil(queue.add("x", cwd: "/code/app", workFolder: scratch.path).workFolder)
        let old = try JSONDecoder().decode(QueueTask.self, from: Data(#"{"id":"1","title":"t"}"#.utf8))
        XCTAssertNil(old.workFolder)
    }

    func testASkillCallIsPreviewedByTheSkillsName() {
        let call = ToolCall(id: "1", name: "use_skill", arguments: #"{"arguments":"to staging","name":"deploy"}"#)
        XCTAssertEqual(Engine.preview(of: call), "deploy")
    }
}
