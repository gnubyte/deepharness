import XCTest
@testable import VisionHarnessCore

/// Against real git, because the point is what git does and refuses to do.
final class GitWorktreesTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private let git = GitWorktrees()

    override func setUpWithError() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Git reports real paths, and the temp folder sits behind a symlink.
        root = URL(fileURLWithPath: realpath(scratch.path, nil).map { String(cString: $0) } ?? scratch.path, isDirectory: true)
        repo = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        sh("git init -q -b main && git config user.email t@example.com && git config user.name T && git config commit.gpgsign false")
        try write("README.md", "hello\n", in: repo)
        sh("git add -A && git commit -qm first")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func sh(_ command: String, in directory: URL? = nil) -> (code: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory ?? repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func write(_ name: String, _ text: String, in folder: URL) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testSlugIsSafeForBranchesAndFolders() {
        XCTAssertEqual(GitWorktrees.slug("Fix the Login Bug!"), "fix-the-login-bug")
        XCTAssertEqual(GitWorktrees.slug("  ../../etc  "), "etc")
        XCTAssertEqual(GitWorktrees.slug("!!!"), "chat")
    }

    func testCreateCutsABranchInASiblingFolder() async throws {
        let ref = try await git.create(from: repo, title: "Add Search")
        XCTAssertEqual(ref.branch, "dsh/add-search")
        XCTAssertEqual(ref.baseBranch, "main")
        XCTAssertEqual(ref.worktreePath, root.appendingPathComponent("app-worktrees/add-search").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ref.worktreePath + "/README.md"))
    }

    func testASecondWorktreeWithTheSameTitleGetsItsOwnName() async throws {
        _ = try await git.create(from: repo, title: "Same")
        let second = try await git.create(from: repo, title: "Same")
        XCTAssertEqual(second.branch, "dsh/same-2")
    }

    func testCreatingFromInsideAWorktreeBranchesFromTheMainCheckout() async throws {
        let first = try await git.create(from: repo, title: "One")
        let second = try await git.create(from: URL(fileURLWithPath: first.worktreePath), title: "Two")
        XCTAssertEqual(second.repoPath, repo.path)
    }

    func testNotARepository() async throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        do {
            _ = try await git.create(from: plain, title: "x")
            XCTFail("should have thrown")
        } catch WorktreeError.notARepository {} catch { XCTFail("\(error)") }
    }

    func testStatusSeesCommitsAndUncommittedFiles() async throws {
        let ref = try await git.create(from: repo, title: "S")
        let folder = URL(fileURLWithPath: ref.worktreePath)
        var status = await git.status(of: ref)
        XCTAssertFalse(status.hasWork)
        try write("new.txt", "x", in: folder)
        status = await git.status(of: ref)
        XCTAssertEqual(status.changedFiles.count, 1)
        try await git.commitAll(ref, message: "work")
        status = await git.status(of: ref)
        XCTAssertEqual(status.ahead, 1)
        XCTAssertFalse(status.isDirty)
    }

    func testMergeThenCleanUpLeavesTheWorkOnMainAndNothingBehind() async throws {
        let ref = try await git.create(from: repo, title: "Feature")
        try write("feature.txt", "x", in: URL(fileURLWithPath: ref.worktreePath))
        try await git.commitAll(ref, message: "feature")
        let outcome = await git.merge(ref, title: "Feature")
        XCTAssertEqual(outcome, .merged(commits: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("feature.txt").path))
        try await git.cleanUp(ref)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ref.worktreePath))
        XCTAssertTrue(sh("git branch --list dsh/feature").out.isEmpty)
    }

    func testAConflictIsAbortedAndChangesNothing() async throws {
        let ref = try await git.create(from: repo, title: "Clash")
        try write("README.md", "theirs\n", in: URL(fileURLWithPath: ref.worktreePath))
        try await git.commitAll(ref, message: "theirs")
        try write("README.md", "ours\n", in: repo)
        sh("git commit -qam ours")
        let head = sh("git rev-parse HEAD").out
        let outcome = await git.merge(ref, title: "Clash")
        XCTAssertEqual(outcome, .conflict(files: ["README.md"]))
        XCTAssertEqual(sh("git rev-parse HEAD").out, head)
        XCTAssertTrue(sh("git status --porcelain").out.isEmpty, "the abort left the checkout clean")
    }

    func testMergeRefusesWhenTheMainCheckoutMovedToAnotherBranch() async throws {
        let ref = try await git.create(from: repo, title: "R")
        try write("r.txt", "x", in: URL(fileURLWithPath: ref.worktreePath))
        try await git.commitAll(ref, message: "r")
        sh("git checkout -qb elsewhere")
        guard case .refused(let why) = await git.merge(ref, title: "R") else { return XCTFail("should refuse") }
        XCTAssertTrue(why.contains("elsewhere"))
    }

    func testMergeRefusesWhenTheMainCheckoutHasUncommittedChanges() async throws {
        let ref = try await git.create(from: repo, title: "D")
        try write("d.txt", "x", in: URL(fileURLWithPath: ref.worktreePath))
        try await git.commitAll(ref, message: "d")
        try write("README.md", "unsaved\n", in: repo)
        guard case .refused = await git.merge(ref, title: "D") else { return XCTFail("should refuse") }
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8), "unsaved\n")
    }

    func testMergeRefusesADirtyWorktree() async throws {
        let ref = try await git.create(from: repo, title: "Dirty")
        try write("x.txt", "x", in: URL(fileURLWithPath: ref.worktreePath))
        guard case .refused = await git.merge(ref, title: "Dirty") else { return XCTFail("should refuse") }
    }

    func testNothingToMerge() async throws {
        let ref = try await git.create(from: repo, title: "Empty")
        let outcome = await git.merge(ref, title: "Empty")
        XCTAssertEqual(outcome, .nothingToMerge)
    }

    func testCleanUpWontLoseUnmergedWork() async throws {
        let ref = try await git.create(from: repo, title: "Keep")
        try write("k.txt", "x", in: URL(fileURLWithPath: ref.worktreePath))
        do {
            try await git.cleanUp(ref)
            XCTFail("a dirty worktree must not be removed")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: ref.worktreePath + "/k.txt"))
    }

    func testDiscardRemovesEverything() async throws {
        let ref = try await git.create(from: repo, title: "Bin")
        try write("b.txt", "x", in: URL(fileURLWithPath: ref.worktreePath))
        try await git.commitAll(ref, message: "b")
        try write("c.txt", "x", in: URL(fileURLWithPath: ref.worktreePath))
        try await git.discard(ref)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ref.worktreePath))
        XCTAssertTrue(sh("git branch --list dsh/bin").out.isEmpty)
    }
}
