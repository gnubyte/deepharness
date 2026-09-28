import Foundation

// MARK: - Generating skills with the model
//
// "Make me a skill that …", or "turn this conversation into a skill". The
// model writes a SKILL.md; the result is normalized, linted, and saved as a
// DRAFT — nothing the model writes becomes active without approval.

public struct SkillGenerationRequest: Sendable {
    /// What the skill should do / when it should be used.
    public var goal: String
    /// A conversation to distil into a skill (optional).
    public var conversation: [LLMMessage]
    /// Names already taken, so the model picks a fresh one.
    public var existingNames: [String]
    /// The current text, when improving an existing skill.
    public var improving: String?

    public init(goal: String, conversation: [LLMMessage] = [], existingNames: [String] = [], improving: String? = nil) {
        self.goal = goal
        self.conversation = conversation
        self.existingNames = existingNames
        self.improving = improving
    }
}

public struct GeneratedSkill: Sendable {
    public let name: String
    public let description: String
    /// The full, normalized SKILL.md.
    public let text: String
    public let issues: [SkillIssue]
}

public enum SkillGenerator {
    public static let systemPrompt = """
    You write agent skills: a SKILL.md file that teaches a coding agent one repeatable job.

    Format — output ONLY the file, starting with the frontmatter, no commentary, no code fence around the whole file:

    ---
    name: lowercase-hyphen-name
    description: One or two sentences saying WHEN to use this skill, with the words a user or task would contain. This line is all the agent sees before deciding to load the skill, so make it specific.
    ---

    # Title

    Then the instructions, in Markdown.

    Rules for a good skill:
    - The description says when to use it (triggers, situations, file types), not just what it is. Under 300 characters.
    - The body is what the agent should DO: a short goal, numbered steps, exact commands and paths, expected output, and the gotchas that actually bite. Be concrete; skip anything a capable agent already knows.
    - Keep it tight: usually 30–150 lines. Put long reference material in separate files and say when to read them (\"see reference/api.md when …\").
    - Verification: end with how to check the work is really done.
    - Never include secrets, tokens, passwords, or personal data. Refer to environment variables instead.
    - Use only tools and commands that exist; do not invent flags.
    - name: lowercase letters, digits and single hyphens, at most 64 characters.
    """

    // MARK: Prompt

    static func userPrompt(_ request: SkillGenerationRequest) -> String {
        var out = "Write a skill for this:\n\n\(request.goal.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if !request.existingNames.isEmpty {
            out += "\nThese skill names already exist — choose a different one: \(request.existingNames.prefix(80).joined(separator: ", ")).\n"
        }
        if let improving = request.improving {
            out += "\nImprove this existing skill instead of starting over; keep what works, fix what doesn't, keep the same name:\n\n<current-skill>\n\(improving)\n</current-skill>\n"
        }
        if !request.conversation.isEmpty {
            out += "\nDistil the reusable procedure from this conversation. Generalize it — drop one-off details (specific file names, this session's errors) unless they are the point:\n\n<conversation>\n\(digest(request.conversation))\n</conversation>\n"
        }
        return out
    }

    /// A compact transcript: what was asked, what the agent did, what came of it.
    public static func digest(_ messages: [LLMMessage], limit: Int = 24_000) -> String {
        var lines: [String] = []
        var used = 0
        for m in messages.reversed() {
            var line: String
            switch m.role {
            case .system: continue
            case .user:
                if m.imageSource != nil { continue }
                line = "User: \(clip(m.content ?? "", 1_500))"
            case .assistant:
                var text = clip(m.content ?? "", 1_200)
                for call in m.toolCalls ?? [] { text += "\n[ran \(call.name) \(clip(call.arguments.raw, 240))]" }
                line = "Assistant: \(text)"
            case .tool:
                line = "  → \(clip(m.content ?? "", 300))"
            }
            used += line.count
            if used > limit { break }
            lines.append(line)
        }
        return lines.reversed().joined(separator: "\n")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n)) + " …"
    }

    // MARK: Reply handling

    /// Pull the skill out of a reply: drop a `<think>` block and a wrapping code fence.
    public static func extract(from reply: String) -> String {
        var text = Compaction.stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        // A whole-file fence: ```markdown\n---\n…\n```
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Chatter before the frontmatter.
        if !text.hasPrefix("---"), let r = text.range(of: "\n---\nname:") {
            text = String(text[text.index(after: r.lowerBound)...])
        }
        return text
    }

    // MARK: Generation

    public static func generate(client: any LLMClient, model: String, request: SkillGenerationRequest,
                                thinking: ThinkingLevel = .low) async throws -> GeneratedSkill {
        var lastError = "The model did not return a skill."
        var feedback: String?
        for attempt in 0..<2 {
            var prompt = userPrompt(request)
            if let feedback { prompt += "\nYour previous attempt was rejected: \(feedback)\nReturn only the corrected SKILL.md file." }
            let llm = LLMRequest(systemPrompt: systemPrompt, messages: [.user(prompt)], tools: [],
                                 model: model, temperature: nil, maxTokens: 6_000, thinking: thinking)
            var text = ""
            for try await event in client.stream(llm) {
                if case .text(let delta) = event { text += delta }
            }
            let file = extract(from: text)
            do {
                let (slug, normalized) = try SkillDrafts.normalize(file)
                let issues = SkillLint.check(normalized)
                if let blocker = issues.first(where: { $0.severity == .error }), attempt == 0 {
                    lastError = blocker.message
                    feedback = blocker.message
                    continue
                }
                let doc = SkillDocument.parse(normalized)
                return GeneratedSkill(name: slug, description: doc["description"] ?? "", text: normalized, issues: issues)
            } catch {
                lastError = error.localizedDescription
                feedback = error.localizedDescription
            }
        }
        throw SkillError.invalid(lastError)
    }
}
