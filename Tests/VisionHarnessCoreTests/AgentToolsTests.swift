import XCTest
@testable import VisionHarnessCore

final class AgentToolsTests: XCTestCase {
    func testModelSearchNeedsEveryWordInAnyOrderAndCase() {
        XCTAssertTrue(ModelSearch.matches(query: "QWEN orb", fields: ["Orbital", "qwen3.6"]))
        XCTAssertFalse(ModelSearch.matches(query: "qwen nebula", fields: ["Orbital", "qwen3.6"]))
        XCTAssertTrue(ModelSearch.matches(query: "   ", fields: []))
    }

    func testANewFileInAFolderBehindTheTmpSymlinkIsStillInside() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/dsh-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let policy = PermissionPolicy(preset: .workspaceWrite, workspaceRoot: folder)
        XCTAssertTrue(policy.resolve(folder.path + "/new.txt").inside)
        XCTAssertFalse(policy.resolve(folder.path + "-sibling/new.txt").inside, "a shared prefix isn't containment")
        XCTAssertFalse(policy.resolve("/private/etc/passwd").inside)
    }

    func testScheduleOnce() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let result = ScheduleRequest.parse(at: "2030-01-01T09:00:00-08:00", cron: nil, everyMinutes: nil, now: now)
        guard case .success(.once) = result else { return XCTFail("\(result)") }
    }

    func testScheduleInThePastIsRefused() {
        let result = ScheduleRequest.parse(at: "2001-01-01T09:00:00Z", cron: nil, everyMinutes: nil)
        guard case .failure = result else { return XCTFail("\(result)") }
    }

    func testScheduleNeedsExactlyOneKind() {
        guard case .failure = ScheduleRequest.parse(at: nil, cron: nil, everyMinutes: nil) else { return XCTFail() }
        guard case .failure = ScheduleRequest.parse(at: nil, cron: "* * * * *", everyMinutes: 5) else { return XCTFail() }
    }

    func testBadCronIsRefused() {
        guard case .failure = ScheduleRequest.parse(at: nil, cron: "every day", everyMinutes: nil) else { return XCTFail() }
        guard case .success(.cron) = ScheduleRequest.parse(at: nil, cron: "30 8 * * 1-5", everyMinutes: nil) else { return XCTFail() }
    }

    func testIntervalMustBePositive() {
        guard case .failure = ScheduleRequest.parse(at: nil, cron: nil, everyMinutes: 0) else { return XCTFail() }
        guard case .success(.interval(let seconds, _)) = ScheduleRequest.parse(at: nil, cron: nil, everyMinutes: 15) else { return XCTFail() }
        XCTAssertEqual(seconds, 900)
    }
}
