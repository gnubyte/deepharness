import Foundation

// MARK: - Skills
//
// A skill is packaged instructions the agent can load when a task matches: a
// folder with a `SKILL.md` (frontmatter `name` + `description`, then Markdown)
// and optional bundled files. The format is shared by Claude Code, Cursor and
// the open Agent Skills convention, so this app reads all of their layouts in
// place and can import/export between them:
//
//   DSH        .dsh/skills/<n>/SKILL.md        ~/Library/Application Support/DSHMac/skills
//   Agents     .agents/skills/<n>/SKILL.md     ~/.agents/skills
//   Qwen Code  .qwen/skills/<n>/SKILL.md
//   Claude     .claude/skills/<n>/SKILL.md     ~/.claude/skills
//              .claude/commands/<n>.md         ~/.claude/commands      (slash commands)
//              .claude/rules/*.md              ~/.claude/rules         (always-on / path-scoped)
//   Cursor     .cursor/skills/<n>/SKILL.md     ~/.cursor/skills
//              .cursor/rules/*.mdc             (alwaysApply / globs / description)
//   Built-in   shipped with the app, installed under Application Support

public enum SkillOrigin: String, Codable, CaseIterable, Sendable {
    case dsh, agents, qwen, claude, cursor, builtin

    public var label: String {
        switch self {
        case .dsh: "DSH"
        case .agents: "Agents"
        case .qwen: "Qwen"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .builtin: "Built-in"
        }
    }

    /// Whether the app owns (and may freely edit/delete) skills from here.
    public var isOwned: Bool { self == .dsh }
}

public enum SkillScope: String, Codable, Sendable {
    case project, user
    public var label: String { self == .project ? "Project" : "User" }
}

public enum SkillKind: String, Codable, Sendable {
    /// A `SKILL.md` folder.
    case skill
    /// A Cursor `.mdc` / Claude `.claude/rules` file.
    case rule
    /// A Claude `.claude/commands/*.md` slash command.
    case command

    public var label: String {
        switch self {
        case .skill: "Skill"
        case .rule: "Rule"
        case .command: "Command"
        }
    }
}

/// Which foreign layouts to read in place. DSH's own and the built-ins are always read.
public struct SkillSources: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let agents = SkillSources(rawValue: 1 << 0)
    public static let qwen = SkillSources(rawValue: 1 << 1)
    public static let claude = SkillSources(rawValue: 1 << 2)
    public static let cursor = SkillSources(rawValue: 1 << 3)
    public static let all: SkillSources = [.agents, .qwen, .claude, .cursor]
}

/// A discovered skill, rule or command.
public struct Skill: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    /// The file that holds it: `SKILL.md`, an `.mdc` rule, or a command `.md`.
    public let url: URL
    public let name: String
    public let description: String
    /// Lower sorts first; matches the precedence of the root it came from.
    public let rank: Int
    public var origin: SkillOrigin
    public var scope: SkillScope
    public var kind: SkillKind
    /// File globs the skill applies to (Cursor `globs`, Claude rule `paths`).
    public var globs: [String]
    /// Always part of the prompt (Cursor `alwaysApply`, a Claude rule without `paths`).
    public var alwaysApply: Bool
    public var argumentHint: String?
    public var allowedTools: [String]
    /// False when the author disabled automatic use (`disable-model-invocation`)
    /// or it's a command / manual-only rule: it then runs only when the user
    /// picks it or types `/name`.
    public var modelInvocable: Bool
    /// False for `user-invocable: false` (background knowledge only).
    public var userInvocable: Bool
    /// A skill with the same name from a higher-precedence root hides this one.
    public var shadowed: Bool

    public init(url: URL, name: String, description: String, rank: Int,
                origin: SkillOrigin = .dsh, scope: SkillScope = .project, kind: SkillKind = .skill,
                globs: [String] = [], alwaysApply: Bool = false, argumentHint: String? = nil,
                allowedTools: [String] = [], modelInvocable: Bool = true, userInvocable: Bool = true,
                shadowed: Bool = false) {
        self.url = url
        self.name = name
        self.description = description
        self.rank = rank
        self.origin = origin
        self.scope = scope
        self.kind = kind
        self.globs = globs
        self.alwaysApply = alwaysApply
        self.argumentHint = argumentHint
        self.allowedTools = allowedTools
        self.modelInvocable = modelInvocable
        self.userInvocable = userInvocable
        self.shadowed = shadowed
    }

    public var slug: String { SkillNaming.slug(name) }

    /// Folder holding bundled files (scripts, references).
    public var directory: URL { url.deletingLastPathComponent() }

    /// Whether removing/editing it touches only files this app created.
    public var isOwned: Bool { origin.isOwned }

    /// The parsed file.
    public func document() -> SkillDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SkillDocument.parse(text)
    }

    /// Files bundled next to a `SKILL.md`, relative to its folder (skills only).
    public func resources(limit: Int = 60) -> [String] {
        guard kind == .skill else { return [] }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        let base = directory.standardizedFileURL.path
        for case let file as URL in en {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            let rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : file.lastPathComponent
            if rel == "SKILL.md" || rel == "skill.md" { continue }
            out.append(rel)
            if out.count >= limit { break }
        }
        return out.sorted()
    }
}

// MARK: - Naming

public enum SkillNaming {
    /// Lowercase ASCII words joined by hyphens, at most 64 characters — the
    /// shape every tool's skill name must take.
    public static func slug(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        var trimmed = String(out.prefix(64))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }

    public static func isValidName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        return s.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    /// `base`, or `base-2`, `base-3` … until `taken` no longer contains it.
    public static func unique(_ base: String, taken: (String) -> Bool) -> String {
        let root = base.isEmpty ? "skill" : base
        if !taken(root) { return root }
        var n = 2
        while taken("\(root)-\(n)") { n += 1 }
        return "\(root)-\(n)"
    }

    public static func firstParagraph(_ text: String, limit: Int = 300) -> String {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !t.hasPrefix("#"), t != "---", !t.hasPrefix("```") {
                return String(t.prefix(limit))
            }
        }
        return ""
    }
}

// MARK: - Where skills live

public struct SkillLocations: Sendable, Equatable {
    public var home: URL
    /// `~/Library/Application Support/DSHMac`
    public var appSupport: URL

    public init(home: URL, appSupport: URL) {
        self.home = home
        self.appSupport = appSupport
    }

    public static var standard: SkillLocations {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return SkillLocations(home: fm.homeDirectoryForCurrentUser,
                              appSupport: support.appendingPathComponent("DSHMac", isDirectory: true))
    }

    /// Skills you own, available in every project.
    public var userSkills: URL { appSupport.appendingPathComponent("skills", isDirectory: true) }
    /// Skills shipped with the app, re-installed on launch.
    public var builtinSkills: URL { appSupport.appendingPathComponent("skills-builtin", isDirectory: true) }
    /// AI-generated and imported skills waiting for approval.
    public var drafts: URL { appSupport.appendingPathComponent("skill-drafts", isDirectory: true) }

    public static func projectSkills(_ project: URL) -> URL {
        project.appendingPathComponent(".dsh/skills", isDirectory: true)
    }
}

// MARK: - Discovery

public struct SkillRoot: Sendable, Equatable {
    public enum Layout: Sendable { case skillDirs, ruleFiles(claudeStyle: Bool), commandFiles }
    public let url: URL
    public let rank: Int
    public let origin: SkillOrigin
    public let scope: SkillScope
    public let layout: Layout

    public static func == (a: SkillRoot, b: SkillRoot) -> Bool { a.url == b.url && a.rank == b.rank }
}

public enum SkillCatalog {
    /// Every root to scan, in precedence order.
    public static func roots(project: URL?, locations: SkillLocations = .standard,
                             sources: SkillSources = .all) -> [SkillRoot] {
        var out: [SkillRoot] = []
        func add(_ url: URL, _ rank: Int, _ origin: SkillOrigin, _ scope: SkillScope, _ layout: SkillRoot.Layout) {
            out.append(SkillRoot(url: url, rank: rank, origin: origin, scope: scope, layout: layout))
        }
        if let project {
            add(project.appendingPathComponent(".dsh/skills"), 100, .dsh, .project, .skillDirs)
            if sources.contains(.agents) { add(project.appendingPathComponent(".agents/skills"), 200, .agents, .project, .skillDirs) }
            if sources.contains(.qwen) { add(project.appendingPathComponent(".qwen/skills"), 300, .qwen, .project, .skillDirs) }
            if sources.contains(.claude) {
                add(project.appendingPathComponent(".claude/skills"), 350, .claude, .project, .skillDirs)
                add(project.appendingPathComponent(".claude/commands"), 355, .claude, .project, .commandFiles)
                add(project.appendingPathComponent(".claude/rules"), 358, .claude, .project, .ruleFiles(claudeStyle: true))
            }
            if sources.contains(.cursor) {
                add(project.appendingPathComponent(".cursor/skills"), 360, .cursor, .project, .skillDirs)
                add(project.appendingPathComponent(".cursor/rules"), 365, .cursor, .project, .ruleFiles(claudeStyle: false))
            }
        }
        add(locations.userSkills, 400, .dsh, .user, .skillDirs)
        let home = locations.home
        if sources.contains(.agents) { add(home.appendingPathComponent(".agents/skills"), 450, .agents, .user, .skillDirs) }
        if sources.contains(.claude) {
            add(home.appendingPathComponent(".claude/skills"), 500, .claude, .user, .skillDirs)
            add(home.appendingPathComponent(".claude/commands"), 505, .claude, .user, .commandFiles)
            add(home.appendingPathComponent(".claude/rules"), 508, .claude, .user, .ruleFiles(claudeStyle: true))
        }
        if sources.contains(.cursor) { add(home.appendingPathComponent(".cursor/skills"), 520, .cursor, .user, .skillDirs) }
        add(locations.builtinSkills, 900, .builtin, .user, .skillDirs)
        return out
    }

    /// Every skill found, best-precedence first; a later duplicate name is
    /// marked `shadowed` rather than dropped so the manager can show it.
    public static func loadAll(project: URL?, locations: SkillLocations = .standard,
                               sources: SkillSources = .all) -> [Skill] {
        var found: [Skill] = []
        for root in roots(project: project, locations: locations, sources: sources) {
            switch root.layout {
            case .skillDirs: found += scanSkillDirs(root)
            case .ruleFiles(let claude): found += scanRules(root, claudeStyle: claude)
            case .commandFiles: found += scanCommands(root)
            }
        }
        found.sort { ($0.rank, $0.name.lowercased()) < ($1.rank, $1.name.lowercased()) }
        var seen = Set<String>()
        for i in found.indices {
            let key = found[i].slug.isEmpty ? found[i].name.lowercased() : found[i].slug
            if seen.contains(key) { found[i].shadowed = true } else { seen.insert(key) }
        }
        return found
    }

    /// The skills that apply (not shadowed).
    public static func load(project: URL?, locations: SkillLocations = .standard,
                            sources: SkillSources = .all) -> [Skill] {
        loadAll(project: project, locations: locations, sources: sources).filter { !$0.shadowed }
    }

    // MARK: Scanners

    static func scanSkillDirs(_ root: SkillRoot) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var out: [Skill] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name.hasPrefix("_") { continue }   // `_drafts` and friends
            var manifest = entry.appendingPathComponent("SKILL.md")
            if !fm.fileExists(atPath: manifest.path) {
                manifest = entry.appendingPathComponent("skill.md")
                guard fm.fileExists(atPath: manifest.path) else { continue }
            }
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            out.append(build(SkillDocument.parse(text), url: manifest, fallbackName: name, root: root, kind: .skill))
        }
        return out
    }

    static func scanRules(_ root: SkillRoot, claudeStyle: Bool) -> [Skill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.url.path),
              let en = fm.enumerator(at: root.url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [Skill] = []
        for case let file as URL in en {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            guard ext == "mdc" || ext == "md" else { continue }
            let base = file.deletingPathExtension().lastPathComponent
            if base.lowercased() == "readme" { continue }
            // Folder-style rule: `<name>/RULE.md(c)` is named after the folder.
            let fallback = base.uppercased() == "RULE" ? file.deletingLastPathComponent().lastPathComponent : base
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            out.append(build(SkillDocument.parse(text), url: file, fallbackName: fallback, root: root,
                             kind: .rule, claudeRuleStyle: claudeStyle))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func scanCommands(_ root: SkillRoot) -> [Skill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.url.path),
              let en = fm.enumerator(at: root.url, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = root.url.standardizedFileURL.path
        var out: [Skill] = []
        for case let file as URL in en {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  file.pathExtension.lowercased() == "md" else { continue }
            let path = file.standardizedFileURL.path
            var rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : file.lastPathComponent
            rel = String(rel.dropLast(3))                       // ".md"
            let name = rel.replacingOccurrences(of: "/", with: ":")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            out.append(build(SkillDocument.parse(text), url: file, fallbackName: name, root: root, kind: .command))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// One parsed file → a `Skill`.
    static func build(_ doc: SkillDocument, url: URL, fallbackName: String, root: SkillRoot,
                      kind: SkillKind, claudeRuleStyle: Bool = false) -> Skill {
        let name = (doc["name"]?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        var globs = doc.list("globs")
        if globs.isEmpty { globs = doc.list("paths") }
        var description = doc["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty { description = doc["when_to_use"] ?? "" }
        let always: Bool
        if let explicit = doc.bool("alwaysApply") {
            always = explicit
        } else if kind == .rule, claudeRuleStyle {
            always = globs.isEmpty          // a Claude rule without `paths` always loads
        } else {
            always = false
        }
        if description.isEmpty {
            description = globs.isEmpty ? SkillNaming.firstParagraph(doc.body)
                                        : "Applies to files matching \(globs.joined(separator: ", "))"
        }
        var invocable = !(doc.bool("disable-model-invocation") ?? false)
        if kind == .command { invocable = false }
        // A Cursor rule with no description, no globs and not always-on is
        // "manual": only attached when the user asks for it.
        if kind == .rule, !always, globs.isEmpty, (doc["description"] ?? "").isEmpty { invocable = false }
        return Skill(url: url, name: name, description: description, rank: root.rank,
                     origin: root.origin, scope: root.scope, kind: kind,
                     globs: globs, alwaysApply: always,
                     argumentHint: doc["argument-hint"],
                     allowedTools: doc.list("allowed-tools"),
                     modelInvocable: invocable,
                     userInvocable: doc.bool("user-invocable") ?? true)
    }
}

// MARK: - Arguments

public enum SkillArguments {
    /// Shell-like split: whitespace separates, quotes group.
    public static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var has = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                has = true
            } else if ch.isWhitespace {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            } else {
                cur.append(ch)
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Fill `$ARGUMENTS` and `$1`…`$9`. A skill that never mentions
    /// `$ARGUMENTS` still gets what the user typed, appended.
    public static func expand(_ body: String, arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = split(trimmed)
        var out = body
        let usesAll = out.contains("$ARGUMENTS")
        out = out.replacingOccurrences(of: "$ARGUMENTS", with: trimmed)
        var usedPositional = false
        if let regex = try? NSRegularExpression(pattern: "\\$([1-9])(?![0-9])") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                usedPositional = true
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let index = Int(ns.substring(with: m.range(at: 1))) ?? 0
                result += index - 1 < parts.count ? parts[index - 1] : ""
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        if !trimmed.isEmpty, !usesAll, !usedPositional {
            out += "\n\nARGUMENTS: \(trimmed)"
        }
        return out
    }
}

// MARK: - What goes into the prompt

/// What the user has chosen for one chat.
public struct SkillSelection: Sendable, Hashable {
    /// Skills the user selected by hand — their full instructions are always in the prompt.
    public var pinned: Set<String>
    /// Whether the model may discover skills itself (the catalog + `use_skill`).
    public var auto: Bool
    /// Skills switched off everywhere.
    public var disabled: Set<String>

    public init(pinned: Set<String> = [], auto: Bool = true, disabled: Set<String> = []) {
        self.pinned = pinned
        self.auto = auto
        self.disabled = disabled
    }
}

public struct SkillPromptResult: Sendable {
    public let text: String
    /// Skills whose full text is in the prompt (always-on rules + pinned).
    public let injected: [Skill]
    /// Skills offered in the catalog for `use_skill`.
    public let catalog: [Skill]
    /// Names left out because of size caps.
    public let skipped: [String]
}

public enum SkillPrompt {
    public static let perSkillCap = 60_000
    public static let totalCap = 200_000
    public static let catalogLimit = 60

    /// The skills in play: not shadowed, not switched off.
    public static func active(_ skills: [Skill], _ selection: SkillSelection) -> [Skill] {
        skills.filter { !$0.shadowed && !selection.disabled.contains($0.id) }
    }

    public static func build(skills: [Skill], selection: SkillSelection) -> SkillPromptResult {
        let live = active(skills, selection)
        var parts: [String] = []
        var injected: [Skill] = []
        var skipped: [String] = []
        var used = 0

        func body(of skill: Skill) -> String? {
            guard let doc = skill.document() else { return nil }
            var text = SkillArguments.expand(doc.body, arguments: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > perSkillCap { text = String(text.prefix(perSkillCap)) + "\n[… truncated; read the file for the rest]" }
            return text
        }

        let always = live.filter { $0.alwaysApply && !selection.pinned.contains($0.id) }
        var alwaysBlocks: [String] = []
        for skill in always {
            guard let text = body(of: skill) else { continue }
            if used + text.count > totalCap { skipped.append(skill.name); continue }
            used += text.count
            injected.append(skill)
            alwaysBlocks.append("### \(skill.name) (\(skill.origin.label) \(skill.kind.label.lowercased()))\n\(text)")
        }
        if !alwaysBlocks.isEmpty {
            parts.append("--- Rules that always apply ---\n" + alwaysBlocks.joined(separator: "\n\n"))
        }

        var pinnedBlocks: [String] = []
        for skill in live where selection.pinned.contains(skill.id) {
            guard let text = body(of: skill) else { continue }
            if used + text.count > totalCap { skipped.append(skill.name); continue }
            used += text.count
            injected.append(skill)
            let dir = skill.kind == .skill ? "\nBase directory for bundled files: \(skill.directory.path)" : ""
            pinnedBlocks.append("### \(skill.name)\(dir)\n\(text)")
        }
        if !pinnedBlocks.isEmpty {
            parts.append("--- Skills the user selected for this chat (follow them) ---\n" + pinnedBlocks.joined(separator: "\n\n"))
        }

        var catalog: [Skill] = []
        if selection.auto {
            catalog = live.filter { $0.modelInvocable && !$0.alwaysApply && !selection.pinned.contains($0.id) }
            if !catalog.isEmpty {
                let shown = catalog.prefix(catalogLimit)
                let lines = shown.map { s -> String in
                    var line = "- \(s.name): \(String(s.description.prefix(300)))"
                    if !s.globs.isEmpty { line += " (files: \(s.globs.prefix(4).joined(separator: ", ")))" }
                    return line
                }
                var block = """
                --- Available skills ---
                Skills are packaged instructions. When the task matches one below, call `use_skill` with its name \
                BEFORE you start, then follow it. Do not load skills that don't apply.
                \(lines.joined(separator: "\n"))
                """
                if catalog.count > shown.count {
                    block += "\n(\(catalog.count - shown.count) more skills exist; call `use_skill` with an unknown name to list them all.)"
                }
                parts.append(block)
            }
        }
        return SkillPromptResult(text: parts.joined(separator: "\n\n"), injected: injected, catalog: catalog, skipped: skipped)
    }
}
