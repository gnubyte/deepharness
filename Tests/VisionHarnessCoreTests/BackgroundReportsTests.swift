import XCTest
@testable import VisionHarnessCore

/// A finished background agent's report is given to the model with the next message. If that request
/// dies before the model saw it (the server is down, an AWS sign-in expired), the report must not be
/// lost: the host puts it back.
final class BackgroundReportsTests: XCTestCase {

    private func makeEngine(_ client: any LLMClient, pool: BackgroundAgents) -> Engine {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        return Engine(client: client, registry: ToolRegistry(tools: []), systemPrompt: "system",
                      config: .init(maxIterations: 3, toolTimeout: 5, model: "test", retry: .off),
                      workspace: root, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                      permissionGate: { _, _, _ in true }, backgroundAgents: pool)
    }

    /// A pool holding one finished job whose report has not been given to anyone.
    private func poolWithAFinishedJob() async -> (BackgroundAgents, BackgroundAgents.Job) {
        let pool = BackgroundAgents()
        guard case .success(let job) = pool.launch(description: "audit the tests", work: { (true, "Found 3 flaky tests.") }) else {
            fatalError("could not launch")
        }
        let done = await pool.wait(job.id, timeout: 5)
        return (pool, done ?? job)
    }

    func testAFailedRunGivesTheReportsItTookBackToThePool() async throws {
        let (pool, job) = await poolWithAFinishedJob()
        let client = FlakyClient(failures: 1, error: LLMError.noModel, turns: [])
        let progress = RunProgress()
        do {
            _ = try await makeEngine(client, pool: pool).run(messages: [], userText: "carry on", progress: progress, sink: { _ in })
            XCTFail("the run should have failed")
        } catch {
            XCTAssertNil(progress.salvaged, "the model never answered")
            XCTAssertEqual(progress.takenReports.map(\.id), [job.id], "the run had taken the report for the model")
            XCTAssertFalse(pool.hasUnreported, "taken, so not announced again by itself")

            pool.requeue(progress.takenReports)
            XCTAssertTrue(pool.hasUnreported, "handed back for the next message")
            XCTAssertEqual(pool.takeUnreported().map(\.id), [job.id])
        }
    }

    func testARunThatSucceededKeepsItsReportsTaken() async throws {
        let (pool, job) = await poolWithAFinishedJob()
        let client = FlakyClient(failures: 0, error: LLMError.noModel, turns: [.init(text: "Thanks, noted.")])
        let progress = RunProgress()
        let result = try await makeEngine(client, pool: pool).run(messages: [], userText: "carry on", progress: progress, sink: { _ in })
        XCTAssertEqual(progress.takenReports.map(\.id), [job.id])
        XCTAssertNotNil(progress.salvaged ?? result.messages, "the model saw it")
        XCTAssertTrue(result.messages.contains { ($0.content ?? "").contains("Found 3 flaky tests.") },
                      "the report reached the model with the message")
        XCTAssertFalse(pool.hasUnreported)
    }

    func testReportsReachTheModelEvenWhenTheCallerTracksNoProgress() async throws {
        // (A caller without a RunProgress must not lose the reports: taking them cannot depend on having a tracker.)
        let (pool, _) = await poolWithAFinishedJob()
        let client = FlakyClient(failures: 0, error: LLMError.noModel, turns: [.init(text: "noted")])
        let result = try await makeEngine(client, pool: pool).run(messages: [], userText: "carry on", sink: { _ in })
        XCTAssertTrue(result.messages.contains { ($0.content ?? "").contains("Found 3 flaky tests.") })
        XCTAssertFalse(pool.hasUnreported)
    }

    func testAStoppedJobIsNeverAnnouncedEvenWhenRequeued() async {
        let pool = BackgroundAgents()
        guard case .success(let job) = pool.launch(description: "slow", work: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return (true, "late")
        }) else { return XCTFail("could not launch") }
        XCTAssertTrue(pool.stop(job.id))
        pool.requeue([pool.job(job.id) ?? job])
        XCTAssertFalse(pool.hasUnreported, "a job the user stopped stays quiet")
    }
}
