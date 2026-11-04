import XCTest
@testable import DSHCore

final class GitSyncTests: XCTestCase {
    /// A scripted git: every command returns a canned answer.
    private func scripted(_ table: @escaping @Sendable ([String]) -> (Int32, String)) -> GitSync {
        GitSync { _, args, _ in table(args) }
    }

    /// Records the git invocations a scenario makes.
    private final class Recorder: @unchecked Sendable {
        var commands: [[String]] = []
        var pushed = false
        var pushArgs: [String] = []
    }

    private func notARepo() -> GitSync {
        scripted { args in
            args.contains("rev-parse") ? (1, "fatal: not a git repository") : (0, "")
        }
    }

    func testSkipsNonRepository() async {
        let report = await notARepo().check(workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(report.outcome, .notARepository)
        XCTAssertNil(report.notice)
    }

    func testSkipsWithoutRemote() async {
        let git = scripted { args in
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "upstream\n") }   // origin absent
            return (0, "")
        }
        let report = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(report.outcome, .noRemote)
    }

    func testUpToDatePullsNothing() async {
        let git = scripted { args in
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "origin") }
            if args.contains("status") { return (0, "## main...origin/main\n") }
            if args.contains("fetch") { return (0, "") }
            return (0, "")
        }
        let report = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(report.outcome, .upToDate)
        XCTAssertNil(report.notice)
    }

    func testPullsWhenBehindAndClean() async {
        let recorder = Recorder()
        let git = GitSync { _, args, _ in
            recorder.commands.append(args)
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "origin") }
            if args.contains("status") { return (0, "## main...origin/main [behind 2]\n") }
            if args.contains("fetch") { return (0, "") }
            if args.contains("merge") { return (0, "") }
            return (0, "")
        }
        let report = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(report.outcome, .pulled(newCommits: 2))
        XCTAssertEqual(report.notice, "🔄 Git sync: pulled 2 new commits from origin into “main”.")
        XCTAssertTrue(recorder.commands.contains { $0.contains("--ff-only") }, "the pull is a fast-forward")
        XCTAssertFalse(recorder.commands.contains { $0.contains("push") }, "nothing to push")
    }

    func testReportsWhenBehindAndDirty() async {
        let git = scripted { args in
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "origin") }
            if args.contains("status") { return (0, "## main...origin/main [behind 1]\n M src/x.swift\n") }
            if args.contains("fetch") { return (0, "") }
            return (0, "")
        }
        let report = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        guard case .needsAttention(let why) = report.outcome else {
            return XCTFail("expected needsAttention, got \(report.outcome)")
        }
        XCTAssertTrue(why.contains("uncommitted changes"))
    }

    func testPushesWhenAhead() async {
        let recorder = Recorder()
        let git = GitSync { _, args, _ in
            recorder.commands.append(args)
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "origin") }
            if args.contains("status") { return (0, "## feat/agent...origin/feat/agent [ahead 3]\n") }
            if args.contains("fetch") { return (0, "") }
            if args.contains("push") { recorder.pushed = true; return (0, "") }
            return (0, "")
        }
        let report = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(report.outcome, .pushed(newCommits: 3))
        XCTAssertTrue(recorder.pushed)
    }

    func testPushWithUpstreamWhenNone() async {
        let recorder = Recorder()
        let git = GitSync { _, args, _ in
            recorder.commands.append(args)
            if args.contains("@{u}") { return (1, "fatal: no upstream configured") }   // no upstream
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "origin") }
            if args.contains("status") { return (0, "## feat/new\n") }
            if args.contains("fetch") { return (0, "") }
            if args.contains("rev-list") { return (0, "0\t2\n") }   // origin has 0, local has 2
            if args.contains("push") { recorder.pushArgs = args; return (0, "") }
            return (0, "")
        }
        _ = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(recorder.pushArgs.contains("-u"), "a branch without upstream gets -u origin <branch>")
        XCTAssertTrue(recorder.pushArgs.contains("feat/new"))
    }

    func testDivergedCleanRebaseConflictAborts() async {
        let recorder = Recorder()
        let git = GitSync { _, args, _ in
            recorder.commands.append(args)
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "origin") }
            if args.contains("status") { return (0, "## main...origin/main [ahead 1, behind 2]\n") }
            if args.contains("fetch") { return (0, "") }
            if args.contains("pull") { return (1, "CONFLICT (content): Merge conflict in src/a.swift") }
            if args.contains("rebase") { return (0, "") }
            return (0, "")
        }
        let report = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        guard case .needsAttention(let why) = report.outcome else {
            return XCTFail("expected needsAttention, got \(report.outcome)")
        }
        XCTAssertTrue(why.contains("conflict"))
        XCTAssertTrue(recorder.commands.contains { $0.contains("--abort") }, "the failed rebase is aborted")
    }

    func testFetchFailureReported() async {
        let git = scripted { args in
            if args.contains("rev-parse") { return (0, "true") }
            if args.contains("remote") { return (0, "origin") }
            if args.contains("status") { return (0, "## main\n") }
            if args.contains("fetch") { return (128, "fatal: could not read from remote repository") }
            return (0, "")
        }
        let report = await git.check(workspace: URL(fileURLWithPath: "/tmp"))
        guard case .failed(let why) = report.outcome else {
            return XCTFail("expected failed, got \(report.outcome)")
        }
        XCTAssertTrue(why.contains("could not fetch"))
    }

    // MARK: Status parsing

    func testParseStatusShapes() {
        func assertParsed(_ status: String, _ branch: String, _ ahead: Int, _ behind: Int,
                          _ dirty: Bool, file: StaticString = #filePath, line: UInt = #line) {
            let p = GitSync.parse(status: status)
            XCTAssertEqual(p?.branch, branch, file: file, line: line)
            XCTAssertEqual(p?.ahead, ahead, file: file, line: line)
            XCTAssertEqual(p?.behind, behind, file: file, line: line)
            XCTAssertEqual(p?.dirty, dirty, file: file, line: line)
        }
        assertParsed("## main...origin/main\n", "main", 0, 0, false)
        assertParsed("## main...origin/main [behind 3]\n", "main", 0, 3, false)
        assertParsed("## main...origin/main [ahead 1, behind 4]\n", "main", 1, 4, false)
        assertParsed("## main...origin/main [ahead 2]\n M a.swift\n", "main", 2, 0, true)
        assertParsed("## feat/x\n", "feat/x", 0, 0, false)
        // Detached HEAD has no clean branch name.
        XCTAssertNil(GitSync.parse(status: "## HEAD (no branch)\n"))
    }

    // MARK: Decline phrases

    func testPromptDeclinesSync() {
        XCTAssertTrue(GitSync.promptDeclinesSync("fix the bug but don't sync with origin"))
        XCTAssertTrue(GitSync.promptDeclinesSync("work offline — no pull"))
        XCTAssertTrue(GitSync.promptDeclinesSync("Do NOT touch git here"))
        XCTAssertFalse(GitSync.promptDeclinesSync("sync the database schema"))
        XCTAssertFalse(GitSync.promptDeclinesSync("add a sync endpoint"))
        // "sync" alone doesn't decline; the decline phrases are specific.
        XCTAssertFalse(GitSync.promptDeclinesSync("make the sync service faster"))
    }

    // MARK: Process runner shape

    func testProcessRunnerRunsGit() async {
        let runner = GitSync.processRunner()
        let result = await runner("/tmp", ["--version"], 10)
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.output.contains("git version"))
    }
}
