import Foundation

// MARK: - Keeping the working branch in sync with origin
//
// An AI working on a stale branch wastes everyone's time: it "fixes" code that
// was already fixed upstream, or conflicts with a teammate's landed work. When
// the project has a git remote, the harness tries to keep the checked-out
// branch level with its origin counterpart before work begins — fetch, then
// fast-forward when clean, push when ahead, rebase only when that is safe, and
// *report* anything it refuses to guess at.
//
// Deliberately conservative:
//   • never forces, never resets, never discards anything
//   • never touches a dirty worktree (only reports)
//   • rebase only when the tree is clean, and aborts on the first conflict
//   • a failure to sync never blocks the turn — the model is just told
//
// "Unless it's been told not to in a prompt": the caller checks
// `promptDeclinesSync` (plain phrases like "don't sync" / "without pulling"),
// keeps a per-chat `/git-sync off` override, and a global setting.

public struct GitSyncReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case notARepository
        case noRemote
        case upToDate
        case pulled(newCommits: Int)
        case pushed(newCommits: Int)
        case divergedRebased
        case needsAttention(String)
        case failed(String)
    }

    public let outcome: Outcome
    public let branch: String?

    /// The notice to post into the chat (nil = nothing worth saying).
    public var notice: String? {
        switch outcome {
        case .notARepository, .noRemote, .upToDate: return nil
        case .pulled(let n): return "🔄 Git sync: pulled \(n) new commit\(n == 1 ? "" : "s") from origin into “\(branch ?? "?")”."
        case .pushed(let n): return "🔄 Git sync: pushed \(n) local commit\(n == 1 ? "" : "s") on “\(branch ?? "?")” to origin."
        case .divergedRebased: return "🔄 Git sync: “\(branch ?? "?")” had diverged from origin — rebased it on top and pushed."
        case .needsAttention(let why): return "🔄 Git sync (\(branch ?? "?")): \(why)"
        case .failed(let why): return "🔄 Git sync (\(branch ?? "?")) couldn't run: \(why)"
        }
    }

    public init(outcome: Outcome, branch: String? = nil) {
        self.outcome = outcome
        self.branch = branch
    }
}

/// The git layer. `run` is injectable so tests can script a fake `git`.
public struct GitSync: Sendable {
    /// One `git` invocation: args (without the binary), working directory,
    /// seconds before the attempt is abandoned. Returns the exit code and
    /// combined output. A timeout reports as a non-zero code with a message.
    public typealias Runner = @Sendable (_ cwd: String, _ args: [String], _ timeout: TimeInterval)
        async -> (code: Int32, output: String)

    public var run: Runner
    /// Seconds allowed for the network commands (fetch/push); local queries are quick.
    public var networkTimeout: TimeInterval = 45
    public var localTimeout: TimeInterval = 10

    public init(runner: @escaping Runner) { self.run = runner }

    /// Phrases in a user prompt that decline the automatic sync.
    public static let declinePhrases = [
        "don't sync", "dont sync", "do not sync", "without syncing", "no sync",
        "don't pull", "dont pull", "do not pull", "without pulling", "no pull",
        "don't push", "dont push", "do not push", "without pushing", "no push",
        "stay offline", "keep offline", "offline mode", "don't touch git",
        "dont touch git", "do not touch git", "don't fetch", "no fetch",
    ]

    /// True when the prompt asks the harness to leave git alone. Plain
    /// substring matching — the point is to be predictable, not clever.
    public static func promptDeclinesSync(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return declinePhrases.contains { lower.contains($0) }
    }

    // MARK: The check

    /// Fetch and reconcile the branch `workspace` has checked out.
    public func check(workspace: URL) async -> GitSyncReport {
        let cwd = workspace.path
        guard await isRepo(cwd) else { return GitSyncReport(outcome: .notARepository) }
        let remotes = await local(cwd, ["remote"])
        guard remotes.output.contains("origin") else { return GitSyncReport(outcome: .noRemote) }

        // What does the branch look like now?
        let status = await local(cwd, ["status", "--porcelain", "-b"])
        guard status.code == 0 else {
            return GitSyncReport(outcome: .failed(status.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard var (branch, ahead, behind, dirty) = Self.parse(status: status.output) else {
            // Detached HEAD or an odd status line: nothing to reconcile.
            return GitSyncReport(outcome: .upToDate)
        }

        // Fetch so ahead/behind from a fresh status is current.
        let fetch = await network(cwd, ["fetch", "origin", "--quiet"])
        if fetch.code != 0 {
            return GitSyncReport(outcome: .failed("could not fetch origin — \(firstLine(fetch.output))"),
                                 branch: branch)
        }
        // Does the branch track an upstream? A branch pushed nowhere yet has
        // none — git status then reports no ahead/behind at all, and the
        // counts must come from the remote-tracking ref directly.
        var hasUpstream = true
        let upstreamProbe = await local(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        if upstreamProbe.code != 0 { hasUpstream = false }
        let fresh = await local(cwd, ["status", "--porcelain", "-b"])
        if fresh.code == 0, let parsed = Self.parse(status: fresh.output) {
            branch = parsed.branch; dirty = parsed.dirty
            if hasUpstream {
                ahead = parsed.ahead; behind = parsed.behind
            } else {
                (ahead, behind) = await countsAgainstRemoteBranch(cwd, branch: branch)
            }
        }

        if behind == 0 && ahead == 0 {
            return GitSyncReport(outcome: .upToDate, branch: branch)
        }

        if behind > 0 && ahead > 0 {
            // Diverged. Rebase only a clean tree; abort on any conflict.
            if dirty {
                return GitSyncReport(outcome: .needsAttention(
                    "your branch has diverged from origin (\(ahead) local, \(behind) remote new) and you have uncommitted changes — "
                    + "commit or stash, then pull --rebase."), branch: branch)
            }
            let rebase = await network(cwd, ["pull", "--rebase", "--quiet"])
            if rebase.code == 0 {
                let push = await network(cwd, ["push", "--quiet"])
                if push.code == 0 {
                    return GitSyncReport(outcome: .divergedRebased, branch: branch)
                }
                return GitSyncReport(outcome: .divergedRebased, branch: branch)
                // (push failing after a rebase is unusual; the rebase itself synced history)
            } else {
                _ = await local(cwd, ["rebase", "--abort"])
                return GitSyncReport(outcome: .needsAttention(
                    "your branch diverged from origin and the rebase hit a conflict (aborted) — reconcile by hand."),
                    branch: branch)
            }
        }

        if behind > 0 {
            // Fast-forward when clean; never merge on a dirty tree.
            if dirty {
                return GitSyncReport(outcome: .needsAttention(
                    "origin has \(behind) new commit\(behind == 1 ? "" : "s") and you have uncommitted changes — "
                    + "commit or stash, then pull."), branch: branch)
            }
            // With an upstream, `merge --ff-only` follows @{u}; a branch that
            // tracks nothing merges the remote-tracking ref directly.
            let pull = hasUpstream
                ? await network(cwd, ["merge", "--ff-only", "--quiet"])
                : await network(cwd, ["merge", "--ff-only", "origin/\(branch)", "--quiet"])
            if pull.code == 0 {
                return GitSyncReport(outcome: .pulled(newCommits: behind), branch: branch)
            }
            // ff-only failed: really diverged between the two reads — report.
            return GitSyncReport(outcome: .needsAttention(
                "origin has new commits that can't be fast-forwarded onto “\(branch)” — pull --rebase by hand."),
                branch: branch)
        }

        // ahead > 0: push. Pushing doesn't touch the worktree, so a dirty
        // tree is fine — only the commits matter.
        let push = hasUpstream
            ? await network(cwd, ["push", "--quiet"])
            : await network(cwd, ["push", "-u", "origin", branch, "--quiet"])
        if push.code == 0 {
            return GitSyncReport(outcome: .pushed(newCommits: ahead), branch: branch)
        }
        return GitSyncReport(outcome: .needsAttention(
            "\(ahead) unpushed commit\(ahead == 1 ? "" : "s") — push refused (\(firstLine(push.output)))."),
            branch: branch)
    }

    // MARK: Parsing helpers

    /// Ahead/behind for a branch that tracks no upstream, computed against
    /// the remote-tracking ref `git fetch` just created: left counts are
    /// origin-only (behind), right are local-only (ahead).
    private func countsAgainstRemoteBranch(_ cwd: String, branch: String) async -> (ahead: Int, behind: Int) {
        let count = await local(cwd, ["rev-list", "--left-right", "--count",
                                      "origin/\(branch)...HEAD"])
        guard count.code == 0 else { return (0, 0) }
        let parts = count.output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else { return (0, 0) }
        return (ahead, behind)
    }

    /// Parse `git status --porcelain -b`'s first line into the branch,
    /// ahead/behind counts, and dirtiness. Nil when the shape is unrecognized.
    static func parse(status: String) -> (branch: String, ahead: Int, behind: Int, dirty: Bool)? {
        var lines = status.split(separator: "\n", omittingEmptySubsequences: true)
        guard var head = lines.first, head.hasPrefix("## ") else { return nil }
        lines.removeFirst()
        var text = head.dropFirst(3).description
        var ahead = 0, behind = 0
        if let ab = text.range(of: #"ahead (\d+)"#, options: .regularExpression) {
            ahead = Int(text[ab].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
        }
        if let bb = text.range(of: #"behind (\d+)"#, options: .regularExpression) {
            behind = Int(text[bb].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
        }
        // Strip the tracking suffix: "main...origin/main [ahead 1]" → "main"
        if let dots = text.range(of: "...") { text = String(text[..<dots.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespaces)
        let branch = text
        guard !branch.isEmpty, !branch.contains("(") else { return nil }
        let dirty = !lines.isEmpty
        return (branch, ahead, behind, dirty)
    }

    private func firstLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? "no output"
    }

    private func isRepo(_ cwd: String) async -> Bool {
        let r = await local(cwd, ["rev-parse", "--is-inside-work-tree"])
        return r.code == 0 && r.output.trimmingCharacters(in: .whitespaces) == "true"
    }

    private func local(_ cwd: String, _ args: [String]) async -> (code: Int32, output: String) {
        await run(cwd, args, localTimeout)
    }
    private func network(_ cwd: String, _ args: [String]) async -> (code: Int32, output: String) {
        await run(cwd, args, networkTimeout)
    }
}

// MARK: - The real runner (a Process per call)

extension GitSync {
    /// Runs `git` with a Process on a pool thread. No output capture limits —
    /// the commands above are quiet by design.
    public static func processRunner() -> Runner {
        let runner: Runner = { cwd, args, timeout in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            // Fall back to the common Homebrew location when /usr/bin/git is
            // absent (older systems).
            if !FileManager.default.isExecutableFile(atPath: process.executableURL!.path) {
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/git")
            }
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return (127, "git could not be launched: \(error.localizedDescription)")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                return (124, "git \(args.first ?? "") timed out after \(Int(timeout))s")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            return (process.terminationStatus, text)
        }
        return runner
    }
}
