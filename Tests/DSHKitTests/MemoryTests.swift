import XCTest
@testable import DSHKit

final class MemoryTests: XCTestCase {
    private var root: URL!
    private var store: MemoryStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-memory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MemoryStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testInstallCreatesTheLayout() throws {
        XCTAssertFalse(store.isInstalled)
        let created = try store.install()

        XCTAssertTrue(store.isInstalled)
        XCTAssertTrue(store.hasMemorySkill)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dailyLog().path))
        XCTAssertTrue(created.contains(store.memoryFile))
        XCTAssertTrue(created.contains(store.agentsFile))
    }

    /// Installing twice must not clobber memory someone has written.
    func testInstallIsIdempotent() throws {
        try store.install()
        try store.writeMemory("# Memory\n\n- a fact worth keeping\n")
        try store.install()
        XCTAssertTrue(read(store.memoryFile).contains("a fact worth keeping"))
    }

    /// The skill must carry the frontmatter the filesystem provider parses.
    func testMemorySkillHasParseableFrontmatter() throws {
        try store.install()
        let body = read(store.memorySkillFile)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.first, "---", "frontmatter must open on line 1")
        XCTAssertTrue(lines.contains { $0.hasPrefix("name: ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("description: ") })
        XCTAssertTrue(body.contains("\n---\n"), "frontmatter must close")
        // The description is the only thing the model sees before loading, so it
        // has to state the trigger.
        XCTAssertTrue(body.contains("description: Use "))
    }

    func testSkillLandsInTheProjectSkillRoot() throws {
        try store.install()
        XCTAssertEqual(
            store.memorySkillFile.path,
            root.appendingPathComponent(".agents/skills/memory/SKILL.md").path
        )
    }

    // MARK: - Injection mirror

    func testMemoryIsMirroredIntoAgentsFile() throws {
        try store.install()
        try store.writeMemory("# Memory\n\n- CANARY_ABC\n")
        let agents = read(store.agentsFile)
        XCTAssertTrue(agents.contains("CANARY_ABC"), "memory must reach the file the harness loads")
        XCTAssertTrue(agents.contains(MemoryStore.blockStart))
        XCTAssertTrue(agents.contains(MemoryStore.blockEnd))
    }

    /// The mirror owns only its own block; hand-written instructions survive.
    func testExistingAgentInstructionsArePreserved() throws {
        let hand = "# Agent instructions\n\nAlways run the linter before pushing.\n"
        try hand.write(to: store.agentsFile, atomically: true, encoding: .utf8)

        try store.install()
        try store.writeMemory("# Memory\n\n- CANARY_DEF\n")

        let agents = read(store.agentsFile)
        XCTAssertTrue(agents.contains("Always run the linter before pushing."))
        XCTAssertTrue(agents.contains("CANARY_DEF"))
    }

    /// Repeated saves replace the block rather than stacking copies.
    func testMirrorReplacesRatherThanAppends() throws {
        try store.install()
        try store.writeMemory("# Memory\n\n- first\n")
        try store.writeMemory("# Memory\n\n- second\n")

        let agents = read(store.agentsFile)
        let blocks = agents.components(separatedBy: MemoryStore.blockStart).count - 1
        XCTAssertEqual(blocks, 1, "one managed block, however many times memory is saved")
        XCTAssertTrue(agents.contains("second"))
        XCTAssertFalse(agents.contains("- first"))
    }

    // MARK: - Daily logs

    func testAppendCreatesAndGrowsTodaysLog() throws {
        try store.appendToLog("chose X over Y")
        try store.appendToLog("dead end: Z does not work")

        let body = read(store.dailyLog())
        XCTAssertTrue(body.contains("chose X over Y"))
        XCTAssertTrue(body.contains("dead end: Z does not work"))
        XCTAssertTrue(
            body.range(of: "chose X over Y")!.lowerBound < body.range(of: "dead end")!.lowerBound,
            "the log is a record, so entries append in order"
        )
    }

    /// Log names are the agent's way of finding a day again, so they must not
    /// vary with the device's locale or calendar.
    func testLogNameIsStableAcrossLocales() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let name = MemoryStore.logName(for: date)
        XCTAssertEqual(name.count, 13, "YYYY-MM-DD.md")
        XCTAssertTrue(name.hasSuffix(".md"))

        let stem = name.dropLast(3)
        let parts = stem.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 4)
        XCTAssertEqual(parts[1].count, 2)
        XCTAssertEqual(parts[2].count, 2)
        XCTAssertTrue(stem.allSatisfy { $0.isNumber || $0 == "-" }, "no localized digits")
    }

    func testLogsListNewestFirst() throws {
        try FileManager.default.createDirectory(at: store.memoryDirectory, withIntermediateDirectories: true)
        for day in ["2026-01-01", "2026-03-05", "2026-02-02"] {
            try "x".write(
                to: store.memoryDirectory.appendingPathComponent("\(day).md"),
                atomically: true,
                encoding: .utf8
            )
        }
        XCTAssertEqual(store.logs().map(\.date), ["2026-03-05", "2026-02-02", "2026-01-01"])
    }
}
