import Foundation

// MARK: - A chat in its own git worktree
//
// A chat can work on an isolated copy of the repository: its own folder, its
// own branch, cut from whatever the main checkout is on. When the work is
// done the app offers to merge the branch back, remove the worktree and
// archive the chat.
//
// Deliberately conservative, like `GitSync`:
//   • a merge happens only into the branch the chat was cut from, only while
//     the main checkout is on that branch and has no uncommitted tracked changes
//   • a conflicting merge is aborted and reported; nothing is left half-merged
//   • cleanup uses `worktree remove` and `branch -d`, both of which refuse to
//     lose work. Only `discard`, which the user confirms, forces.

/// Where a worktree chat lives. Stored with the chat.
public struct WorktreeRef: Codable, Hashable, Sendable {
    /// The main checkout the worktree was made from.
    public var repoPath: String
    public var worktreePath: String
    public var branch: String
    /// The branch it was cut from, and where it merges back.
    public var baseBranch: String
    public var createdAt: Date

    public init(repoPath: String, worktreePath: String, branch: String, baseBranch: String, createdAt: Date = .now) {
        self.repoPath = repoPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseBranch = baseBranch
        self.createdAt = createdAt
    }
}

/// What a worktree holds that isn't on its base branch yet.
public struct WorktreeStatus: Hashable, Sendable {
    /// Commits on the worktree's branch that the base branch doesn't have.
    public var ahead: Int
    /// Commits the base branch gained since the worktree was cut.
    public var behind: Int
    /// `git status --porcelain` lines: uncommitted and untracked files.
    public var changedFiles: [String]
    /// False when the folder is gone (removed by hand, or from another chat).
    public var exists: Bool

    public init(ahead: Int = 0, behind: Int = 0, changedFiles: [String] = [], exists: Bool = true) {
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.exists = exists
    }

    public var isDirty: Bool { !changedFiles.isEmpty }
    public var hasWork: Bool { ahead > 0 || isDirty }
}

public enum WorktreeError: LocalizedError, Equatable {
    case notARepository(String)
    case detachedHead
    case noCommits
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path): "\(path) isn't a git repository, so it can't have a worktree."
        case .detachedHead: "The project is on a detached HEAD. Check out a branch first; the worktree needs a branch to merge back into."
        case .noCommits: "This repository has no commits yet, so there is nothing to branch from."
        case .git(let detail): detail
        }
    }
}

public enum WorktreeMergeOutcome: Equatable, Sendable {
    case merged(commits: Int)
    /// The branch has nothing the base doesn't. Safe to clean up.
    case nothingToMerge
    /// The merge was not attempted. Nothing changed. The reason is user-facing.
    case refused(String)
    /// The merge hit conflicts and was aborted. Nothing changed.
    case conflict(files: [String])
}

public struct GitWorktrees: Sendable {
    public var run: GitSync.Runner
    public var timeout: TimeInterval = 60

    public init(runner: @escaping GitSync.Runner = GitSync.processRunner()) {
        self.run = runner
    }

    private func git(_ cwd: String, _ args: [String]) async -> (code: Int32, output: String) {
        await run(cwd, args, timeout)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Paths and names

    /// `feature/My Task!` → `my-task`: safe in a branch name and a folder name.
    public static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        let capped = String(out.prefix(40))
        let clean = capped.hasSuffix("-") ? String(capped.dropLast()) : capped
        return clean.isEmpty ? "chat" : clean
    }

    /// Worktrees of `/code/app` live together in `/code/app-worktrees/`.
    public static func container(forRepo repo: URL) -> URL {
        repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + "-worktrees", isDirectory: true)
    }

    // MARK: Create

    /// The main checkout that `folder` belongs to, which is `folder`'s own
    /// repository root unless `folder` is itself a linked worktree.
    public func mainCheckout(of folder: URL) async -> String? {
        let common = await git(folder.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common.code == 0 else { return nil }
        let path = Self.trimmed(common.output)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == ".git" { return url.deletingLastPathComponent().path }
        // A bare repository, or a `--separate-git-dir`: fall back to the toplevel.
        let top = await git(folder.path, ["rev-parse", "--show-toplevel"])
        return top.code == 0 ? Self.trimmed(top.output) : nil
    }

    /// Cut a new branch and worktree from the branch the main checkout is on.
    public func create(from folder: URL, title: String) async throws -> WorktreeRef {
        guard let repo = await mainCheckout(of: folder) else {
            throw WorktreeError.notARepository(folder.path)
        }
        let hasCommit = await git(repo, ["rev-parse", "--verify", "--quiet", "HEAD"])
        guard hasCommit.code == 0 else { throw WorktreeError.noCommits }
        let head = await git(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"])
        guard head.code == 0 else { throw WorktreeError.detachedHead }
        let base = Self.trimmed(head.output)

        let repoURL = URL(fileURLWithPath: repo)
        let container = Self.container(forRepo: repoURL)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let slug = Self.slug(title)
        var name = slug
        var attempt = 1
        while true {
            let branchTaken = await git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/dsh/\(name)"])
            let folderTaken = FileManager.default.fileExists(atPath: container.appendingPathComponent(name).path)
            if branchTaken.code != 0 && !folderTaken { break }
            attempt += 1
            name = "\(slug)-\(attempt)"
        }
        let branch = "dsh/\(name)"
        let path = container.appendingPathComponent(name, isDirectory: true).path
        let added = await git(repo, ["worktree", "add", "-b", branch, path, base])
        guard added.code == 0 else {
            throw WorktreeError.git("Couldn't create the worktree: \(Self.trimmed(added.output))")
        }
        return WorktreeRef(repoPath: repo, worktreePath: path, branch: branch, baseBranch: base)
    }

    // MARK: Status

    public func status(of ref: WorktreeRef) async -> WorktreeStatus {
        guard FileManager.default.fileExists(atPath: ref.worktreePath) else {
            return WorktreeStatus(exists: false)
        }
        var status = WorktreeStatus()
        let counts = await git(ref.worktreePath, ["rev-list", "--left-right", "--count", "\(ref.baseBranch)...\(ref.branch)"])
        if counts.code == 0 {
            let parts = Self.trimmed(counts.output).split(whereSeparator: \.isWhitespace)
            if parts.count == 2 {
                status.behind = Int(parts[0]) ?? 0
                status.ahead = Int(parts[1]) ?? 0
            }
        }
        let changes = await git(ref.worktreePath, ["status", "--porcelain"])
        if changes.code == 0 {
            status.changedFiles = changes.output.split(separator: "\n").map(String.init)
        }
        return status
    }

    /// Commit everything in the worktree, so it can merge.
    public func commitAll(_ ref: WorktreeRef, message: String) async throws {
        let add = await git(ref.worktreePath, ["add", "-A"])
        guard add.code == 0 else { throw WorktreeError.git("git add failed: \(Self.trimmed(add.output))") }
        let commit = await git(ref.worktreePath, ["commit", "-m", message])
        guard commit.code == 0 else { throw WorktreeError.git("git commit failed: \(Self.trimmed(commit.output))") }
    }

    // MARK: Merge

    /// Merge the worktree's branch into its base branch, in the main checkout.
    public func merge(_ ref: WorktreeRef, title: String) async -> WorktreeMergeOutcome {
        let current = await status(of: ref)
        guard current.exists else {
            return .refused("The worktree folder is gone: \(ref.worktreePath)")
        }
        guard !current.isDirty else {
            return .refused("The worktree has uncommitted changes. Commit them before merging.")
        }
        guard current.ahead > 0 else { return .nothingToMerge }

        let head = await git(ref.repoPath, ["symbolic-ref", "--quiet", "--short", "HEAD"])
        let onBranch = Self.trimmed(head.output)
        guard head.code == 0, onBranch == ref.baseBranch else {
            let where_ = head.code == 0 ? "“\(onBranch)”" : "a detached HEAD"
            return .refused("The main checkout is on \(where_), not “\(ref.baseBranch)”. Switch it to “\(ref.baseBranch)” and try again.")
        }
        let dirty = await git(ref.repoPath, ["status", "--porcelain", "--untracked-files=no"])
        guard dirty.code == 0 else { return .refused("Couldn't read the main checkout: \(Self.trimmed(dirty.output))") }
        guard Self.trimmed(dirty.output).isEmpty else {
            return .refused("The main checkout has uncommitted changes. Commit or stash them, then try again.")
        }

        let oneLine = title.split(separator: "\n").first.map(String.init) ?? title
        let merged = await git(ref.repoPath, ["merge", "--no-ff", "--no-edit",
                                              "-m", "Merge \(ref.branch): \(oneLine)", ref.branch])
        if merged.code == 0 { return .merged(commits: current.ahead) }

        let unmerged = await git(ref.repoPath, ["diff", "--name-only", "--diff-filter=U"])
        let files = unmerged.output.split(separator: "\n").map(String.init)
        let inProgress = await git(ref.repoPath, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"])
        if inProgress.code == 0 {
            _ = await git(ref.repoPath, ["merge", "--abort"])
            return .conflict(files: files)
        }
        return .refused("git merge failed: \(Self.trimmed(merged.output))")
    }

    // MARK: Clean up

    /// Remove a merged worktree and its branch. Refuses to lose work: git
    /// won't remove a dirty worktree or delete an unmerged branch.
    public func cleanUp(_ ref: WorktreeRef) async throws {
        if FileManager.default.fileExists(atPath: ref.worktreePath) {
            let removed = await git(ref.repoPath, ["worktree", "remove", ref.worktreePath])
            guard removed.code == 0 else {
                throw WorktreeError.git("Couldn't remove the worktree: \(Self.trimmed(removed.output))")
            }
        }
        _ = await git(ref.repoPath, ["worktree", "prune"])
        let deleted = await git(ref.repoPath, ["branch", "-d", ref.branch])
        guard deleted.code == 0 else {
            throw WorktreeError.git("Removed the worktree, but kept branch “\(ref.branch)”: \(Self.trimmed(deleted.output))")
        }
    }

    /// Throw the work away: force-remove the worktree and force-delete its
    /// branch. Only for an explicit, confirmed "discard".
    public func discard(_ ref: WorktreeRef) async throws {
        if FileManager.default.fileExists(atPath: ref.worktreePath) {
            let removed = await git(ref.repoPath, ["worktree", "remove", "--force", ref.worktreePath])
            guard removed.code == 0 else {
                throw WorktreeError.git("Couldn't remove the worktree: \(Self.trimmed(removed.output))")
            }
        }
        _ = await git(ref.repoPath, ["worktree", "prune"])
        _ = await git(ref.repoPath, ["branch", "-D", ref.branch])
    }
}
