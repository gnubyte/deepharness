import Foundation

// MARK: - use_skill

/// Loads a skill's full instructions. The system prompt lists skills by name
/// and description only; this is how the model reads the one that applies.
public struct UseSkillTool: ToolExecutor {
    public static let name = "use_skill"
    public static let spec = ToolSpec(
        name: name,
        description: "Load a skill's full instructions (and its bundled files) before doing a task the skill covers. Skills are listed in the system prompt with when to use each. Pass the exact skill name; pass an unknown name to list every skill.",
        parameters: """
        {"type":"object","properties":{"name":{"type":"string","description":"Skill name, exactly as listed"},"arguments":{"type":"string","description":"Optional arguments for the skill ($ARGUMENTS)"}},"required":["name"]}
        """
    )

    /// Skills in play for this chat (already filtered for enabled/shadowed).
    public let skills: [Skill]

    public init(skills: [Skill]) { self.skills = skills }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let requested = (Self.string(args, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = Self.string(args, "arguments") ?? ""
        let key = SkillNaming.slug(requested.hasPrefix("/") ? String(requested.dropFirst()) : requested)
        guard !requested.isEmpty, let skill = skills.first(where: { $0.slug == key || $0.name.lowercased() == requested.lowercased() }) else {
            let names = skills.filter(\.modelInvocable).map(\.name)
            return ToolResult(output: "Error: no skill named “\(requested)”. Available: \(names.isEmpty ? "(none)" : names.joined(separator: ", ")).")
        }
        guard skill.modelInvocable || skill.alwaysApply else {
            return ToolResult(output: "Error: “\(skill.name)” is a command the user runs themselves (\(skill.kind.label.lowercased())); it is not available for automatic use.")
        }
        guard let doc = skill.document() else {
            return ToolResult(output: "Error: can't read \(skill.url.path).")
        }
        var body = SkillArguments.expand(doc.body, arguments: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        var truncated = false
        if body.count > SkillPrompt.perSkillCap {
            body = String(body.prefix(SkillPrompt.perSkillCap))
            truncated = true
        }
        var out = "# Skill: \(skill.name) (\(skill.origin.label) \(skill.kind.label.lowercased()), \(skill.scope.label.lowercased()))\n"
        if skill.kind == .skill { out += "Base directory: \(skill.directory.path)\n" }
        if !skill.allowedTools.isEmpty { out += "Suggested tools: \(skill.allowedTools.joined(separator: ", "))\n" }
        out += "\n" + body
        if truncated { out += "\n\n[… truncated; read \(skill.url.path) for the rest]" }
        let files = skill.resources()
        if !files.isEmpty {
            out += "\n\nBundled files (relative to the base directory; read them with read_file when the instructions say so):\n"
            out += files.map { "- \($0)" }.joined(separator: "\n")
        }
        return ToolResult(output: out)
    }
}

// MARK: - propose_skill

/// Lets the agent write down a reusable procedure as a DRAFT. Nothing the
/// agent proposes is active until the user approves it in Skills.
public struct ProposeSkillTool: ToolExecutor {
    public static let name = "propose_skill"
    public static let spec = ToolSpec(
        name: name,
        description: "Propose a reusable skill (a saved procedure) for the user to review. Use when the user asks you to make a skill, or after finishing a multi-step workflow worth repeating. It is saved as a DRAFT the user must approve — it is not active in this conversation. Write the description as WHEN to use it.",
        parameters: """
        {"type":"object","properties":{"name":{"type":"string","description":"lowercase-hyphen name, e.g. godot-export-android"},"description":{"type":"string","description":"One or two sentences: when to use this skill, with trigger words"},"instructions":{"type":"string","description":"The skill body in Markdown: goal, numbered steps, exact commands, gotchas"},"scope":{"type":"string","enum":["project","user"],"description":"project = this project only (default); user = every project"}},"required":["name","description","instructions"]}
        """
    )

    public let projectRoot: URL?
    public let locations: SkillLocations

    public init(projectRoot: URL?, locations: SkillLocations = .standard) {
        self.projectRoot = projectRoot
        self.locations = locations
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let name = Self.string(args, "name") ?? ""
        let description = (Self.string(args, "description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = (Self.string(args, "instructions") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scope: SkillScope = Self.string(args, "scope") == "user" ? .user : .project
        let slug = SkillNaming.slug(name)
        guard !slug.isEmpty else { return ToolResult(output: "Error: give the skill a lowercase-hyphen name.") }
        guard !description.isEmpty else { return ToolResult(output: "Error: the description must say when to use the skill.") }
        guard instructions.count >= 20 else { return ToolResult(output: "Error: the instructions are empty or too short to be useful.") }
        guard instructions.count <= 60_000 else { return ToolResult(output: "Error: the instructions are too long (max 60,000 characters). Split it, or keep reference material in a file.") }
        let text = "---\nname: \(slug)\ndescription: \(SkillDocument.scalar(description))\n---\n\n\(instructions)\n"
        do {
            let draft = try SkillDrafts.create(text: text, scope: scope, projectRoot: projectRoot,
                                               source: "agent", locations: locations)
            let issues = SkillLint.check(text).filter { $0.severity >= .warning }
            var out = "Saved draft “\(draft.name)” for the user's review. It is NOT active yet — the user has to approve it in Skills (Settings ▸ Skills, or the Skills button in the chat). Don't rely on it in this conversation; carry on with the task."
            if !issues.isEmpty { out += "\nNotes: " + issues.map(\.message).joined(separator: " ") }
            return ToolResult(output: out)
        } catch {
            return ToolResult(output: "Error: \(error.localizedDescription)")
        }
    }
}
