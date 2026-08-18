import Foundation

/// Durable agent memory kept as files inside a project.
///
/// Files, not a database, for the reason the approach exists: the agent can
/// read and edit them with the tools it already has, they diff and review like
/// anything else in the repo, and nothing is trapped behind a client that has
/// to be running. `MEMORY.md` is injected into every session by the harness's
/// own instruction loader; the daily logs are read on demand.
public struct MemoryStore: Sendable {
    /// Project folder — the session cwd the agent works in.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Layout

    /// Durable cross-session facts — the file of record, and what you edit.
    public var memoryFile: URL { root.appendingPathComponent("MEMORY.md") }

    /// The file the harness actually injects.
    ///
    /// `agent-instructions` accepts an `instructionFileCandidates` config and
    /// the composed profile tree shows `MEMORY.md` in it, but the running
    /// harness does not honour it: in a project root where `AGENTS.md` loads
    /// 16 KiB of instructions, a `MEMORY.md` beside it loads nothing. Rather
    /// than depend on a key that silently does not take effect, memory is
    /// mirrored into a managed block of `AGENTS.md`, which is loaded reliably.
    public var agentsFile: URL { root.appendingPathComponent("AGENTS.md") }

    /// Working logs, one per day. Never auto-injected.
    public var memoryDirectory: URL { root.appendingPathComponent("memory", isDirectory: true) }

    /// Where a project's own skills live, in the harness's highest-rank root.
    public var skillsDirectory: URL {
        root.appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    public var memorySkillFile: URL {
        skillsDirectory
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    /// Dates are the log's identity, so they are formatted in a fixed locale
    /// and calendar rather than the user's — a device set to a non-Gregorian
    /// calendar would otherwise name files the agent cannot find again.
    public static func logName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func dailyLog(for date: Date = Date()) -> URL {
        memoryDirectory.appendingPathComponent(Self.logName(for: date))
    }

    // MARK: - State

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: memoryFile.path)
    }

    public var hasMemorySkill: Bool {
        FileManager.default.fileExists(atPath: memorySkillFile.path)
    }

    // MARK: - Reading

    public func readMemory() -> String? {
        try? String(contentsOf: memoryFile, encoding: .utf8)
    }

    public func readLog(for date: Date = Date()) -> String? {
        try? String(contentsOf: dailyLog(for: date), encoding: .utf8)
    }

    /// Existing logs, newest first.
    public func logs(limit: Int = 60) -> [(date: String, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: memoryDirectory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".md") }
            .sorted(by: >)
            .prefix(limit)
            .map { (String($0.dropLast(3)), memoryDirectory.appendingPathComponent($0)) }
    }

    // MARK: - Writing

    public func writeMemory(_ text: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: memoryFile, atomically: true, encoding: .utf8)
        try syncToAgentsFile(text)
    }

    // MARK: - Injection

    static let blockStart = "<!-- dsh:memory:start — managed by DSH.app; edit MEMORY.md instead -->"
    static let blockEnd = "<!-- dsh:memory:end -->"

    /// Mirror `MEMORY.md` into a managed block of `AGENTS.md`.
    ///
    /// Everything outside the markers is left exactly as found, so a project
    /// that already has agent instructions keeps them and this only owns its
    /// own block. Replacing the whole file would silently destroy hand-written
    /// instructions the first time memory was saved.
    public func syncToAgentsFile(_ memory: String) throws {
        let block = """
        \(Self.blockStart)

        ## Memory

        Durable facts for this project. The file of record is `MEMORY.md`; this
        copy is what gets loaded into your context. Working notes for today are
        in `memory/\(Self.logName(for: Date()))` — read that yourself when you need it.

        \(memory.trimmingCharacters(in: .whitespacesAndNewlines))

        \(Self.blockEnd)
        """

        let existing = (try? String(contentsOf: agentsFile, encoding: .utf8)) ?? ""

        let updated: String
        if let start = existing.range(of: Self.blockStart),
           let end = existing.range(of: Self.blockEnd), start.lowerBound < end.lowerBound {
            updated = existing.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
        } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated = "# Agent instructions\n\n\(block)\n"
        } else {
            updated = existing.hasSuffix("\n") ? "\(existing)\n\(block)\n" : "\(existing)\n\n\(block)\n"
        }
        try updated.write(to: agentsFile, atomically: true, encoding: .utf8)
    }

    /// Append a timestamped entry to today's log, creating it if needed.
    public func appendToLog(_ text: String, at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        let url = dailyLog(for: date)

        var body = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(Self.logName(for: date).dropLast(3))\n"
        if !body.hasSuffix("\n") { body += "\n" }

        let time = DateFormatter.logTime.string(from: date)
        body += "\n- \(time) — \(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Install

    /// Create the memory layout and the skill that teaches its protocol.
    ///
    /// Existing files are never overwritten: a project that already has memory
    /// keeps it, and installing again only fills in what is missing.
    @discardableResult
    public func install() throws -> [URL] {
        var created: [URL] = []
        let fm = FileManager.default

        try fm.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: memoryFile.path) {
            try Self.memoryTemplate.write(to: memoryFile, atomically: true, encoding: .utf8)
            created.append(memoryFile)
        }
        // Mirror whatever MEMORY.md now holds, so a project that already had one
        // starts being injected immediately rather than on the next edit.
        try syncToAgentsFile(readMemory() ?? Self.memoryTemplate)
        if !created.contains(agentsFile) { created.append(agentsFile) }

        let today = dailyLog()
        if !fm.fileExists(atPath: today.path) {
            let header = "# \(Self.logName(for: Date()).dropLast(3))\n\nWorking log. Decisions and state for today.\n"
            try header.write(to: today, atomically: true, encoding: .utf8)
            created.append(today)
        }

        if !fm.fileExists(atPath: memorySkillFile.path) {
            try fm.createDirectory(
                at: memorySkillFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.memorySkillTemplate.write(to: memorySkillFile, atomically: true, encoding: .utf8)
            created.append(memorySkillFile)
        }

        return created
    }

    // MARK: - Templates

    static let memoryTemplate = """
    # Memory

    Durable facts that should survive every session. Injected automatically, so
    keep it short — a cheat sheet, not a journal. Anything long-winded belongs
    in a skill; anything that changes daily belongs in `memory/YYYY-MM-DD.md`.

    ## Project

    <!-- What this project is, and anything the agent cannot infer from the code. -->

    ## Preferences

    <!-- How work should be done here: style, tools, what to avoid. -->

    ## Decisions

    <!-- Choices already made, so they are not relitigated. Include the why. -->

    """

    static let memorySkillTemplate = """
    ---
    name: memory
    description: Use at the start of any session in this project, before answering the first question, and again whenever a decision is made, a preference is stated, or a task's state changes. Covers reading MEMORY.md and today's working log, appending to memory/YYYY-MM-DD.md, and deciding what belongs in durable memory versus a daily log versus a skill.
    ---

    # Memory protocol

    This project keeps memory as files. If it is not written to a file, it does
    not survive compaction or the end of the session.

    ## Layout

    | Path | Lifetime | Loaded |
    |---|---|---|
    | `MEMORY.md` | durable | automatically, every session |
    | `memory/YYYY-MM-DD.md` | one day | on demand — read it yourself |
    | `.agents/skills/<name>/SKILL.md` | durable | on demand, by name |

    ## At the start of a session

    `MEMORY.md` is already in your context — do not re-read it. Read today's log,
    and yesterday's if today's is thin:

    ```bash
    cat memory/$(date +%F).md 2>/dev/null
    ```

    ## While working

    Append to today's log when something happens that a later session would need
    and could not re-derive: a decision and its reason, a task's state, a dead end
    worth not repeating.

    ```bash
    echo "- $(date +%H:%M) — chose X over Y because Z" >> memory/$(date +%F).md
    ```

    Append rather than rewrite. The log is a record, not a summary.

    ## What goes where

    - **`MEMORY.md`** — facts true across sessions: what the project is, standing
      preferences, decisions already settled. Keep it under ~100 lines. It costs
      tokens on every single request, so a fact that stops being true is worse
      than one that was never written.
    - **`memory/YYYY-MM-DD.md`** — today's state and reasoning. Cheap, because it
      is only read when asked for.
    - **A skill** — anything procedural. A workflow written into `MEMORY.md` is
      paid for on every request; the same workflow as a skill is paid for only
      when used.

    ## Promoting and pruning

    When a daily entry turns out to be durable — a preference confirmed twice, a
    decision that stuck — move it up into `MEMORY.md` and keep the log entry where
    it is. When a line in `MEMORY.md` becomes false, delete it. Stale memory is
    actively harmful: it is asserted with the same confidence as everything else.

    ## Searching

    ```bash
    grep -ril "topic" MEMORY.md memory/
    ```

    Read the matching file rather than trusting the grep line alone — entries
    carry their reasoning on the lines around them.
    """
}

extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}
