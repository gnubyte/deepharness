import Foundation

// MARK: - Errors

public enum SkillError: LocalizedError, Sendable, Equatable {
    case exists(String)
    case notFound(String)
    case invalid(String)
    case tooLarge(String)
    case unsupported(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .exists(let m), .notFound(let m), .invalid(let m), .tooLarge(let m), .unsupported(let m), .io(let m): m
        }
    }
}

/// What to do when the destination already holds a skill of that name.
public enum ConflictPolicy: Sendable, Equatable {
    case fail, replace, rename
}

// MARK: - Safe file copying

enum SkillFiles {
    static let maxFileBytes = 5_000_000
    static let maxTotalBytes = 25_000_000
    static let maxFiles = 2_000
    static let skipNames: Set<String> = [".DS_Store", ".git", ".svn", "node_modules", "__pycache__", ".venv", "venv"]

    /// Copy a folder's regular files. Symlinks are never followed (a skill must
    /// not smuggle in a link to `~/.ssh`), VCS/dependency folders are skipped,
    /// and size/count limits keep an import from copying a whole repository.
    /// `excluding` names top-level entries to leave out. Returns the file count.
    @discardableResult
    static func copyTree(from src: URL, to dst: URL, excluding: Set<String> = []) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                                     options: []) else {
            throw SkillError.io("Can't read \(src.lastPathComponent).")
        }
        let base = src.standardizedFileURL.path
        var files = 0
        var total = 0
        for case let item as URL in en {
            let name = item.lastPathComponent
            let rel = item.standardizedFileURL.path.hasPrefix(base + "/")
                ? String(item.standardizedFileURL.path.dropFirst(base.count + 1)) : name
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if skipNames.contains(name) || (!rel.contains("/") && excluding.contains(name)) {
                if values?.isDirectory == true { en.skipDescendants() }
                continue
            }
            if values?.isSymbolicLink == true { continue }
            let target = dst.appendingPathComponent(rel)
            if values?.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            if size > maxFileBytes { throw SkillError.tooLarge("\(rel) is \(size / 1_000_000) MB; skill files may be at most \(maxFileBytes / 1_000_000) MB.") }
            total += size
            files += 1
            if files > maxFiles || total > maxTotalBytes {
                throw SkillError.tooLarge("That folder is too large to be a skill (over \(maxFiles) files or \(maxTotalBytes / 1_000_000) MB).")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: item, to: target)
        }
        return files
    }

    /// Put `staged` at `final`, honouring the conflict policy. Returns where it landed.
    static func place(_ staged: URL, at final: URL, conflict: ConflictPolicy) throws -> URL {
        let fm = FileManager.default
        var dest = final
        if fm.fileExists(atPath: dest.path) {
            switch conflict {
            case .fail:
                throw SkillError.exists("A skill named “\(final.lastPathComponent)” already exists there.")
            case .replace:
                try fm.removeItem(at: dest)
            case .rename:
                let parent = final.deletingLastPathComponent()
                let name = SkillNaming.unique(final.lastPathComponent) { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }
                dest = parent.appendingPathComponent(name)
            }
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staged, to: dest)
        return dest
    }

    static func stagingDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dsh-skill-\(UUID().uuidString)", isDirectory: true)
    }
}

// MARK: - Conversion between layouts

public enum SkillConverter {
    /// Write `skill` as a portable skill folder (`SKILL.md` + bundled files) at
    /// `dir`. A Cursor rule keeps its `globs`/`alwaysApply`; a Claude command
    /// becomes a skill only the user can invoke.
    public static func writeSkillFolder(_ skill: Skill, to dir: URL, name: String? = nil) throws {
        let fm = FileManager.default
        switch skill.kind {
        case .skill:
            try SkillFiles.copyTree(from: skill.directory, to: dir)
            if let name, var doc = skill.document() {       // renamed on import
                doc["name"] = name
                try doc.render().write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            }
        case .rule, .command:
            guard let source = skill.document() else { throw SkillError.io("Can't read \(skill.url.lastPathComponent).") }
            var doc = SkillDocument(body: source.body, hadFrontmatter: true)
            doc["name"] = name ?? SkillNaming.slug(skill.name).nonEmptyOr("skill")
            doc["description"] = skill.description
            if !skill.globs.isEmpty { doc.setList("globs", skill.globs) }
            if skill.alwaysApply { doc["alwaysApply"] = "true" }
            if let hint = skill.argumentHint { doc["argument-hint"] = hint }
            if !skill.allowedTools.isEmpty { doc.setList("allowed-tools", skill.allowedTools) }
            if skill.kind == .command || !skill.modelInvocable { doc["disable-model-invocation"] = "true" }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try doc.render().write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
    }

    /// Cursor `.mdc` text for a skill.
    public static func cursorRule(for skill: Skill) -> String? {
        guard let source = skill.document() else { return nil }
        var doc = SkillDocument(body: source.body, hadFrontmatter: true)
        doc["description"] = skill.description
        if !skill.globs.isEmpty { doc.setList("globs", skill.globs) }
        doc["alwaysApply"] = skill.alwaysApply ? "true" : "false"
        var out = doc
        let extras = skill.resources()
        if !extras.isEmpty {
            out.body += "\n\n<!-- Bundled files (copied next to this rule in .cursor/skills/\(skill.slug)/): \(extras.prefix(12).joined(separator: ", ")) -->"
        }
        return out.render()
    }

    /// Claude `.claude/commands/<name>.md` text for a skill.
    public static func claudeCommand(for skill: Skill) -> String? {
        guard let source = skill.document() else { return nil }
        var doc = SkillDocument(body: source.body, hadFrontmatter: true)
        doc["description"] = skill.description
        if let hint = skill.argumentHint { doc["argument-hint"] = hint }
        if !skill.allowedTools.isEmpty { doc.setList("allowed-tools", skill.allowedTools) }
        return doc.render()
    }
}

extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Drafts (awaiting approval)

/// A skill that exists but isn't active yet: AI-generated, proposed by the
/// agent, or imported "for review". Drafts live in Application Support, not in
/// any repository; approving one moves it to its destination.
public struct SkillDraft: Identifiable, Hashable, Sendable {
    public var id: String { directory.lastPathComponent }
    public let directory: URL
    public var skillFile: URL { directory.appendingPathComponent("SKILL.md") }
    public let name: String
    public let description: String
    /// Where it goes when approved.
    public let scope: SkillScope
    public let projectPath: String?
    /// "ai" (generated in the app), "agent" (proposed mid-chat), "chat" (from a conversation), "import".
    public let source: String
    public let createdAt: Date
    public let note: String?

    public var sourceLabel: String {
        switch source {
        case "agent": "Proposed by the agent"
        case "ai": "Generated with AI"
        case "chat": "Made from a chat"
        case "import": "Imported"
        default: source.capitalized
        }
    }
}

struct DraftMeta: Codable {
    var scope: SkillScope
    var projectPath: String?
    var source: String
    var createdAt: Date
    var note: String?
}

public enum SkillDrafts {
    static let metaName = "draft.json"

    public static func list(locations: SkillLocations = .standard) -> [SkillDraft] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: locations.drafts, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [SkillDraft] = []
        for dir in dirs {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { continue }
            let doc = SkillDocument.parse(text)
            let meta = (try? Data(contentsOf: dir.appendingPathComponent(metaName)))
                .flatMap { try? decoder.decode(DraftMeta.self, from: $0) }
                ?? DraftMeta(scope: .user, projectPath: nil, source: "import", createdAt: .distantPast, note: nil)
            out.append(SkillDraft(directory: dir,
                                  name: doc["name"] ?? dir.lastPathComponent,
                                  description: doc["description"] ?? SkillNaming.firstParagraph(doc.body),
                                  scope: meta.scope, projectPath: meta.projectPath,
                                  source: meta.source, createdAt: meta.createdAt, note: meta.note))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Turn free text into a well-formed SKILL.md: a valid slug `name`, a
    /// `description`, and the body. Text without frontmatter is accepted (the
    /// name/description come from the arguments).
    public static func normalize(_ text: String, fallbackName: String? = nil,
                                 fallbackDescription: String? = nil) throws -> (slug: String, text: String) {
        var doc = SkillDocument.parse(text)
        let rawName = (doc["name"] ?? fallbackName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = SkillNaming.slug(rawName)
        guard !slug.isEmpty else { throw SkillError.invalid("The skill needs a name (letters, numbers, hyphens).") }
        let description = (doc["description"] ?? fallbackDescription ?? SkillNaming.firstParagraph(doc.body))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw SkillError.invalid("The skill needs a description saying when to use it.") }
        guard !doc.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillError.invalid("The skill has no instructions.")
        }
        if !doc.hadFrontmatter { doc.hadFrontmatter = true }
        // Name first, description second, whatever else the author had after.
        var ordered = SkillDocument(body: doc.body, hadFrontmatter: true)
        ordered["name"] = slug
        ordered["description"] = description
        for key in doc.order where key != "name" && key != "description" {
            if let v = doc.fields[key] { ordered[key] = v } else if let l = doc.lists[key] { ordered.setList(key, l) }
        }
        return (slug, ordered.render())
    }

    /// Save a new draft from full SKILL.md text.
    @discardableResult
    public static func create(text: String, fallbackName: String? = nil, fallbackDescription: String? = nil,
                              scope: SkillScope, projectRoot: URL?, source: String, note: String? = nil,
                              locations: SkillLocations = .standard) throws -> SkillDraft {
        let (slug, normalized) = try normalize(text, fallbackName: fallbackName, fallbackDescription: fallbackDescription)
        let fm = FileManager.default
        try fm.createDirectory(at: locations.drafts, withIntermediateDirectories: true)
        let dirName = SkillNaming.unique(slug) { fm.fileExists(atPath: locations.drafts.appendingPathComponent($0).path) }
        let dir = locations.drafts.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try normalized.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try writeMeta(DraftMeta(scope: scope, projectPath: projectRoot?.path, source: source, createdAt: .now, note: note), in: dir)
        guard let draft = list(locations: locations).first(where: { $0.directory.standardizedFileURL == dir.standardizedFileURL }) else {
            throw SkillError.io("Couldn't save the draft.")
        }
        return draft
    }

    /// Stage a whole skill folder (with bundled files) as a draft.
    @discardableResult
    public static func stage(folder: URL, scope: SkillScope, projectRoot: URL?, source: String, note: String? = nil,
                             locations: SkillLocations = .standard) throws -> SkillDraft {
        let fm = FileManager.default
        try fm.createDirectory(at: locations.drafts, withIntermediateDirectories: true)
        let slug = SkillNaming.slug(folder.lastPathComponent).nonEmptyOr("skill")
        let dirName = SkillNaming.unique(slug) { fm.fileExists(atPath: locations.drafts.appendingPathComponent($0).path) }
        let dir = locations.drafts.appendingPathComponent(dirName, isDirectory: true)
        try SkillFiles.copyTree(from: folder, to: dir)
        guard fm.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) else {
            try? fm.removeItem(at: dir)
            throw SkillError.invalid("\(folder.lastPathComponent) has no SKILL.md.")
        }
        try writeMeta(DraftMeta(scope: scope, projectPath: projectRoot?.path, source: source, createdAt: .now, note: note), in: dir)
        guard let draft = list(locations: locations).first(where: { $0.directory.standardizedFileURL == dir.standardizedFileURL }) else {
            throw SkillError.io("Couldn't save the draft.")
        }
        return draft
    }

    private static func writeMeta(_ meta: DraftMeta, in dir: URL) throws {
        try encoder.encode(meta).write(to: dir.appendingPathComponent(metaName))
    }

    /// Replace a draft's SKILL.md (the review editor's Save).
    public static func update(_ draft: SkillDraft, text: String) throws {
        let (_, normalized) = try normalize(text)
        try normalized.write(to: draft.skillFile, atomically: true, encoding: .utf8)
    }

    /// Change where an approved draft will go.
    public static func retarget(_ draft: SkillDraft, scope: SkillScope, projectRoot: URL?) throws {
        let meta = DraftMeta(scope: scope, projectPath: projectRoot?.path ?? draft.projectPath,
                             source: draft.source, createdAt: draft.createdAt, note: draft.note)
        try writeMeta(meta, in: draft.directory)
    }

    /// Where approving would put it.
    public static func destination(for draft: SkillDraft, projectRoot: URL?, locations: SkillLocations = .standard) throws -> URL {
        let slug = SkillNaming.slug(draft.name).nonEmptyOr(draft.id)
        switch draft.scope {
        case .user:
            return locations.userSkills.appendingPathComponent(slug, isDirectory: true)
        case .project:
            guard let root = projectRoot ?? draft.projectPath.map({ URL(fileURLWithPath: $0) }) else {
                throw SkillError.invalid("Open a project first, or make this a user skill (available in every project).")
            }
            return SkillLocations.projectSkills(root).appendingPathComponent(slug, isDirectory: true)
        }
    }

    /// Activate a draft: move it to its destination and delete the draft.
    @discardableResult
    public static func approve(_ draft: SkillDraft, projectRoot: URL?, conflict: ConflictPolicy = .fail,
                               locations: SkillLocations = .standard) throws -> URL {
        let dest = try destination(for: draft, projectRoot: projectRoot, locations: locations)
        let staged = SkillFiles.stagingDirectory()
        do {
            try SkillFiles.copyTree(from: draft.directory, to: staged, excluding: [metaName])
            let landed = try SkillFiles.place(staged, at: dest, conflict: conflict)
            try? FileManager.default.removeItem(at: draft.directory)
            return landed.appendingPathComponent("SKILL.md")
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    public static func reject(_ draft: SkillDraft) throws {
        try FileManager.default.removeItem(at: draft.directory)
    }
}

// MARK: - Managing active skills

public enum SkillManager {
    /// A starting point for a hand-written skill.
    public static func scaffold(name: String, description: String) -> String {
        """
        ---
        name: \(SkillNaming.slug(name).nonEmptyOr("new-skill"))
        description: \(description.isEmpty ? "Use when …" : description)
        ---

        # \(name)

        ## When to use

        ## Steps

        1.
        """
    }

    /// The folder a new skill of this scope is written under.
    public static func base(scope: SkillScope, projectRoot: URL?, locations: SkillLocations = .standard) throws -> URL {
        switch scope {
        case .user: return locations.userSkills
        case .project:
            guard let projectRoot else { throw SkillError.invalid("Open a project first, or make this a user skill.") }
            return SkillLocations.projectSkills(projectRoot)
        }
    }

    /// Write a new active skill from SKILL.md text.
    @discardableResult
    public static func create(text: String, scope: SkillScope, projectRoot: URL?,
                              conflict: ConflictPolicy = .fail, locations: SkillLocations = .standard) throws -> URL {
        let (slug, normalized) = try SkillDrafts.normalize(text)
        let base = try base(scope: scope, projectRoot: projectRoot, locations: locations)
        let staged = SkillFiles.stagingDirectory()
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        do {
            try normalized.write(to: staged.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let landed = try SkillFiles.place(staged, at: base.appendingPathComponent(slug), conflict: conflict)
            return landed.appendingPathComponent("SKILL.md")
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Copy a Claude/Cursor/Agents skill, rule or command into DSH's own store so
    /// it can be edited and shared without touching the other tool's files.
    @discardableResult
    public static func adopt(_ skill: Skill, scope: SkillScope, projectRoot: URL?,
                             conflict: ConflictPolicy = .rename, locations: SkillLocations = .standard) throws -> URL {
        let base = try base(scope: scope, projectRoot: projectRoot, locations: locations)
        let slug = SkillNaming.slug(skill.name).nonEmptyOr("skill")
        let staged = SkillFiles.stagingDirectory()
        do {
            try SkillConverter.writeSkillFolder(skill, to: staged, name: slug)
            let landed = try SkillFiles.place(staged, at: base.appendingPathComponent(slug), conflict: conflict)
            return landed.appendingPathComponent("SKILL.md")
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Full text of the file.
    public static func read(_ skill: Skill) -> String {
        (try? String(contentsOf: skill.url, encoding: .utf8)) ?? ""
    }

    /// Save edits (only for skills this app owns — foreign files are adopted first).
    public static func write(_ skill: Skill, text: String) throws {
        guard skill.isOwned else { throw SkillError.unsupported("This skill belongs to \(skill.origin.label). Copy it to DSH first to edit it.") }
        try text.write(to: skill.url, atomically: true, encoding: .utf8)
    }

    /// Move to the Trash — recoverable, and works for foreign files too.
    public static func trash(_ skill: Skill) throws {
        let target = skill.kind == .skill ? skill.directory : skill.url
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }
}

// MARK: - Linting

public struct SkillIssue: Sendable, Equatable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case info = 0, warning = 1, error = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public let severity: Severity
    public let message: String
    public var id: String { "\(severity.rawValue):\(message)" }
}

public enum SkillLint {
    public static func check(_ text: String) -> [SkillIssue] {
        var out: [SkillIssue] = []
        let doc = SkillDocument.parse(text)
        if !doc.hadFrontmatter {
            out.append(.init(severity: .error, message: "Add a frontmatter block (--- name: … description: … ---) at the top."))
        }
        let name = doc["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty {
            out.append(.init(severity: .error, message: "Missing `name`."))
        } else if !SkillNaming.isValidName(name) {
            out.append(.init(severity: .warning, message: "Use a lowercase-hyphen name (\(SkillNaming.slug(name).nonEmptyOr("my-skill"))) — Claude and Cursor expect it, max 64 characters."))
        }
        let description = doc["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty {
            out.append(.init(severity: .error, message: "Missing `description`: it is the only thing the model sees before deciding to load the skill."))
        } else {
            if description.count > 1024 { out.append(.init(severity: .warning, message: "The description is over 1,024 characters; other tools truncate it.")) }
            if description.count < 25 { out.append(.init(severity: .warning, message: "The description is very short — say when to use the skill and what it covers.")) }
            let lower = description.lowercased()
            if !(lower.contains("use ") || lower.contains("when") || lower.contains("if ")) {
                out.append(.init(severity: .info, message: "Say WHEN it applies (e.g. “Use when debugging …”), not only what it is."))
            }
        }
        let body = doc.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { out.append(.init(severity: .error, message: "The skill has no instructions.")) }
        let lines = body.components(separatedBy: "\n").count
        if lines > 500 { out.append(.init(severity: .warning, message: "\(lines) lines is long — move reference material into files next to SKILL.md and say when to read them.")) }
        let secretPatterns = ["sk-[A-Za-z0-9]{20,}", "AKIA[0-9A-Z]{16}", "-----BEGIN [A-Z ]*PRIVATE KEY-----",
                              "gh[pousr]_[A-Za-z0-9]{30,}", "xox[baprs]-[A-Za-z0-9-]{10,}"]
        for pattern in secretPatterns where text.range(of: pattern, options: .regularExpression) != nil {
            out.append(.init(severity: .warning, message: "This looks like it contains a secret (key/token). Skills are shared as plain files — remove it."))
            break
        }
        return out.sorted { $0.severity > $1.severity }
    }
}
