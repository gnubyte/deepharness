import XCTest
@testable import VisionHarnessCore

final class HarnessMemoryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeMemory() -> HarnessMemory {
        HarnessMemory(appSupport: dir)
    }

    func testSetUpScaffolds() throws {
        let memory = makeMemory()
        try memory.setUp()
        XCTAssertTrue(FileManager.default.fileExists(atPath: memory.memoryFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memory.dailyFile().path))
    }

    func testAppendDurableAndDaily() throws {
        let memory = makeMemory()
        memory.append("Patrick prefers small verifiable steps.", durable: true)
        memory.append("Deploy uses ./bundle.sh release.", durable: true)
        memory.append("Working on the fleet test today.", durable: false)

        let durable = try XCTUnwrap(String(contentsOf: memory.memoryFile, encoding: .utf8))
        XCTAssertTrue(durable.contains("small verifiable steps"))
        XCTAssertTrue(durable.contains("bundle.sh release"))
        let daily = try XCTUnwrap(String(contentsOf: memory.dailyFile(), encoding: .utf8))
        XCTAssertTrue(daily.contains("fleet test"))
        XCTAssertFalse(daily.contains("bundle.sh release"), "the daily log doesn't hold durable facts")
    }

    func testPromptBlockCarriesBothLayers() throws {
        let memory = makeMemory()
        memory.append("Uses Amazon Bedrock via the dsh-bedrock profile.", durable: true)
        memory.append("Today: investigating the swapper.", durable: false)
        let block = memory.promptBlock()
        XCTAssertTrue(block.contains("Harness memory"))
        XCTAssertTrue(block.contains("dsh-bedrock"))
        XCTAssertTrue(block.contains("swapper"))
    }

    func testPromptBlockEmptyWhenNoMemory() {
        XCTAssertTrue(makeMemory().promptBlock().isEmpty)
    }

    func testRecordKeyFactsGoesToDaily() throws {
        let memory = makeMemory()
        memory.recordKeyFacts(["The org's SSO profile is dsh-bedrock.", "QA runs on Fridays."])
        let daily = try XCTUnwrap(String(contentsOf: memory.dailyFile(), encoding: .utf8))
        XCTAssertTrue(daily.contains("Key facts from compaction"))
        XCTAssertTrue(daily.contains("dsh-bedrock"))
        XCTAssertTrue(daily.contains("Fridays"))
    }

    // MARK: Key-facts extraction

    func testKeyFactsExtraction() {
        let summary = """
        ## Task
        Fix the swapper.

        ## Decisions
        Use ff-only pulls.

        ## Work done
        Edited AppTransport.

        ## Key facts
        - The Spark serves on 192.168.68.69:8999 with a pinned self-signed cert.
        - Patrick's Guardian account uses TOTP 2FA.
        * The org's AWS profile is dsh-bedrock.

        ## State
        Tests pass.
        """
        let facts = Compaction.keyFacts(from: summary)
        XCTAssertEqual(facts.count, 3)
        XCTAssertTrue(facts[0].contains("192.168.68.69"))
        XCTAssertTrue(facts[2].contains("dsh-bedrock"))
    }

    func testKeyFactsNoneAndMissing() {
        XCTAssertEqual(Compaction.keyFacts(from: "## Key facts\nNone\n"), [])
        XCTAssertTrue(Compaction.keyFacts(from: "No key facts section here").isEmpty)
    }
}
