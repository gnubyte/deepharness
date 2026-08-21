import Foundation

/// A project instruction file the agent loads on every turn.
public struct InstructionFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let text: String
    /// Display name, relative to the project root.
    public let label: String

    public init(url: URL, text: String, label: String) {
        self.url = url
        self.text = text
        self.label = label
    }

    public var lineCount: Int { text.isEmpty ? 0 : text.components(separatedBy: "\n").count }
}

/// A discovered skill: a `SKILL.md` with frontmatter naming when it applies.
public struct Skill: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let description: String
    /// Lower sorts first; matches the precedence of the root it came from.
    public let rank: Int

    public init(url: URL, name: String, description: String, rank: Int) {
        self.url = url
        self.name = name
        self.description = description
        self.rank = rank
    }
}

/// Everything the app knows about a project folder that shapes the system
/// prompt: instruction/memory files and the skill catalog.
///
/// The old client had to mirror `MEMORY.md` into `AGENTS.md` because an
/// external harness owned prompt assembly. This app *is* the harness, so the
/// files are read and injected directly — no managed blocks, no markers.
public struct ProjectContext: Sendable {
    public let root: URL
    public let instructions: [InstructionFile]
    public let skills: [Skill]

    public init(root: URL, instructions: [InstructionFile], skills: [Skill]) {
        self.root = root
        self.instructions = instructions
        self.skills = skills
    }

    /// Instruction files are looked for in this order; every one that exists
    /// is loaded. `AGENTS.md` and `QWEN.md` keep us compatible with projects
    /// already set up for other agents.
    public static let instructionNames = ["AGENTS.md", "QWEN.md", "CLAUDE.md", "DSH.md", "MEMORY.md"]

    /// Skill roots, highest precedence (lowest rank) first.
    public static func skillRoots(project: URL) -> [(url: URL, rank: Int)] {
        [
            (project.appendingPathComponent(".dsh/skills"), 100),
            (project.appendingPathComponent(".agents/skills"), 200),
            (project.appendingPathComponent(".qwen/skills"), 300),
            (Self.userSkillsDirectory, 400),
        ]
    }

    public static var userSkillsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DSHMac/skills", isDirectory: true)
    }

    /// Read the project's instruction files and skill catalog from disk.
    public static func load(root: URL) -> ProjectContext {
        var instructions: [InstructionFile] = []
        for name in instructionNames {
            let url = root.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            instructions.append(InstructionFile(url: url, text: text, label: name))
        }
        // Today's daily memory log, if the project keeps one.
        let today = Self.dayStamp()
        let daily = root.appendingPathComponent("memory/\(today).md")
        if let text = try? String(contentsOf: daily, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instructions.append(InstructionFile(url: daily, text: text, label: "memory/\(today).md"))
        }

        var skills: [Skill] = []
        var seen = Set<String>()
        for (dir, rank) in skillRoots(project: root) {
            for skill in scanSkills(in: dir, rank: rank) where !seen.contains(skill.name) {
                seen.insert(skill.name)
                skills.append(skill)
            }
        }
        skills.sort { ($0.rank, $0.name) < ($1.rank, $1.name) }
        return ProjectContext(root: root, instructions: instructions, skills: skills)
    }

    public static func dayStamp(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// A skill is a directory holding a `SKILL.md`.
    private static func scanSkills(in dir: URL, rank: Int) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out: [Skill] = []
        for entry in entries {
            let manifest = entry.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            let front = frontmatter(text)
            let name = front["name"] ?? entry.lastPathComponent
            let description = front["description"] ?? firstParagraph(text)
            out.append(Skill(url: manifest, name: name, description: description, rank: rank))
        }
        return out
    }

    /// Minimal `key: value` frontmatter reader — enough for `name` and
    /// `description`, which is all the catalog shows.
    public static func frontmatter(_ text: String) -> [String: String] {
        var lines = text.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines = lines.dropFirst()
        var out: [String: String] = [:]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count > 1 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private static func firstParagraph(_ text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed != "---" {
                return String(trimmed.prefix(200))
            }
        }
        return ""
    }

    // MARK: - Prompt assembly

    /// The block appended to the system prompt for this project.
    ///
    /// Skills are advertised by name + description only; the model reads the
    /// `SKILL.md` with `read_file` when one applies. That keeps the per-turn
    /// cost of a large catalog to a couple of lines each.
    public func promptSupplement(environment: String) -> String {
        var parts: [String] = [environment]

        for file in instructions {
            parts.append("""
            --- \(file.label) (project instructions — follow these) ---
            \(file.text.trimmingCharacters(in: .whitespacesAndNewlines))
            """)
        }

        if !skills.isEmpty {
            let catalog = skills.map { "- \($0.name): \($0.description) [\($0.url.path)]" }
                .joined(separator: "\n")
            parts.append("""
            --- Available skills ---
            When a task matches one of these, read its SKILL.md with `read_file` first and follow it.
            \(catalog)
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Machine facts the model would otherwise guess at.
    public static func environmentBlock(workspace: URL, model: String, preset: PermissionPreset) -> String {
        var lines = [
            "--- Environment ---",
            "Project folder: \(workspace.path)",
            "Platform: macOS",
            "Today's date: \(dayStamp())",
            "Model: \(model)",
            "Permission preset: \(preset.rawValue)",
        ]
        if let branch = gitBranch(at: workspace) {
            lines.append("Git branch: \(branch)")
        }
        return lines.joined(separator: "\n")
    }

    /// Current branch, read straight from `.git/HEAD` — no subprocess, so this
    /// is safe to call while assembling a prompt.
    public static func gitBranch(at root: URL) -> String? {
        let head = root.appendingPathComponent(".git/HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return String(trimmed.prefix(8))  // detached HEAD
    }

    // MARK: - Authoring

    /// Create the memory scaffold a project needs: `MEMORY.md` plus today's
    /// daily log. Existing files are left alone.
    @discardableResult
    public static func setUpMemory(root: URL) throws -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []

        let memory = root.appendingPathComponent("MEMORY.md")
        if !fm.fileExists(atPath: memory.path) {
            try """
            # Project memory

            Durable facts about this project. Loaded into every session, so keep it short —
            detail belongs in a skill, and today's state belongs in the daily log.

            -
            """.write(to: memory, atomically: true, encoding: .utf8)
            created.append(memory)
        }

        let dailyDir = root.appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let daily = dailyDir.appendingPathComponent("\(dayStamp()).md")
        if !fm.fileExists(atPath: daily.path) {
            try "# \(dayStamp())\n\n- \n".write(to: daily, atomically: true, encoding: .utf8)
            created.append(daily)
        }
        return created
    }

    /// Scaffold a new skill under `<project>/.agents/skills/<slug>/SKILL.md`.
    @discardableResult
    public static func createSkill(root: URL, name: String, description: String) throws -> URL {
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let dir = root.appendingPathComponent(".agents/skills/\(slug)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SKILL.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        State *when* this skill applies in the description above — that line is all the
        model sees before deciding to load this file.

        ## Steps

        1.
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
