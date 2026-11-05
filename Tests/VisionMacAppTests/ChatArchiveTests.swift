import XCTest
@testable import VisionMacApp
import VisionHarnessCore

@MainActor
final class ChatArchiveTests: XCTestCase {
    private var root: URL!
    private var log: ConversationLog!
    private var archive: ChatArchive!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("arc-\(UUID().uuidString)", isDirectory: true)
        log = ConversationLog(dir: root.appendingPathComponent("conversations"))
        log.writeDelay = 0
        archive = ChatArchive(directory: root.appendingPathComponent("archive"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ id: String, title: String = "Fix login", text: String = "the zebra word") {
        log.upsert(id: id, cwd: "/code/app", title: title, preset: nil)
        log.recordItem(id, kind: "user", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        log.recordItem(id, kind: "tool", text: "ok", toolName: "read_file", argSummary: "a.txt", output: "contents", isError: false)
        log.flush(wait: true)
    }

    func testArchivingMovesTheChatAndKeepsAReadableCopy() throws {
        seed("c1")
        archive.archive("c1", from: log, reason: "Merged")
        XCTAssertNil(log.session("c1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.directory.appendingPathComponent("c1.json").path))
        XCTAssertEqual(archive.chats.map(\.title), ["Fix login"])
        XCTAssertEqual(archive.chats[0].reason, "Merged")
        let markdown = try String(contentsOf: archive.directory.appendingPathComponent("c1.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("the zebra word"))
        XCTAssertTrue(markdown.contains("read_file"))
    }

    func testAMissingKeyInAnOldChatFileStillLoads() throws {
        let file = log.directory.appendingPathComponent("old.json")
        try #"{"session":{"id":"old","title":"Old","updatedAt":1000},"items":[]}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(log.adopt(fileAt: file)?.title, "Old")
    }

    func testRestoreBringsItBackWithItsTimeline() throws {
        seed("c2")
        archive.archive("c2", from: log, reason: "x")
        let row = try XCTUnwrap(archive.restore("c2", into: log))
        XCTAssertNil(row.archivedAt)
        XCTAssertTrue(archive.chats.isEmpty)
        XCTAssertEqual(log.loadItems("c2").first?.text, "the zebra word")
        XCTAssertEqual(log.loadItems("c2").last?.output, "contents", "nothing in the row was lost")
    }

    func testRestoringAFinishedWorktreeChatPointsAtItsProject() throws {
        seed("c3")
        log.updateMeta("c3") {
            $0.worktree = WorktreeRef(repoPath: "/code/app", worktreePath: "/nowhere/gone", branch: "dsh/x", baseBranch: "main")
            $0.cwd = "/nowhere/gone"
        }
        archive.archive("c3", from: log, reason: "x")
        XCTAssertEqual(archive.chats[0].project, "app", "filed under the repo, not the worktree")
        XCTAssertEqual(archive.chats[0].branch, "dsh/x")
        let row = try XCTUnwrap(archive.restore("c3", into: log))
        XCTAssertEqual(row.cwd, "/code/app")
        XCTAssertNil(row.worktree)
    }

    func testSearchReadsTitlesAndMessages() {
        seed("c4", title: "Fix login", text: "the zebra word")
        seed("c5", title: "Other", text: "nothing here")
        archive.archive("c4", from: log, reason: "x")
        archive.archive("c5", from: log, reason: "x")
        let chats = archive.chats
        XCTAssertEqual(ChatArchive.search("zebra", in: chats).map(\.id), ["c4"])
        XCTAssertEqual(ChatArchive.search("other", in: chats).map(\.id), ["c5"])
        XCTAssertTrue(ChatArchive.search("absent", in: chats).isEmpty)
    }

    func testDeleteForever() {
        seed("c6")
        archive.archive("c6", from: log, reason: "x")
        archive.deleteForever("c6")
        XCTAssertTrue(archive.chats.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.directory.appendingPathComponent("c6.json").path))
    }

    func testMetadataSurvivesAReload() {
        seed("c7")
        log.updateMeta("c7") {
            $0.additionalFolders = ["/code/other"]
            $0.kind = "agent"
            $0.person = GuardianPerson(id: "p", displayName: "Dana")
        }
        log.flush(wait: true)
        let again = ConversationLog(dir: log.directory)
        let row = again.session("c7")
        XCTAssertEqual(row?.additionalFolders, ["/code/other"])
        XCTAssertEqual(row?.kind, "agent")
        XCTAssertEqual(row?.person?.displayName, "Dana")
    }
}
