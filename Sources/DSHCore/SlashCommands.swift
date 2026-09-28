import Foundation

// MARK: - Slash commands
//
// Typed into the composer. Only these exact words are commands — anything
// else starting with "/" (a path like /Users/me/x) goes to the model as-is.

public enum SlashCommand: Equatable, Sendable {
    /// Summarize the conversation now; optional focus for the summary.
    case compact(focus: String?)
    /// Work on a task in a loop until the model declares it complete.
    case goal(String)
    /// Show or set this chat's thinking level ("default" clears the override).
    case think(String?)
    /// Show the detected context window and usage.
    case context
    /// Show the Spark's models, or switch the Spark to one ("/swap flash").
    case swap(String?)
    /// List skills and what is selected for this chat.
    case skills
    /// "/skill <name>" toggles a skill for this chat; "/skill new <what it should do>" writes one.
    case skill(String?)
    case help

    public struct Info: Sendable {
        public let usage: String
        public let summary: String
        public init(usage: String, summary: String) {
            self.usage = usage
            self.summary = summary
        }
    }

    public static let catalog: [Info] = [
        .init(usage: "/goal <task>", summary: "Keep working until the task is done (the model says GOAL_COMPLETE)"),
        .init(usage: "/compact [focus]", summary: "Summarize the conversation now to free up context"),
        .init(usage: "/think off|low|medium|high|max|default", summary: "Set how hard the model thinks in this chat"),
        .init(usage: "/context", summary: "Show the model's context window and how much is used"),
        .init(usage: "/swap [model]", summary: "Show the Spark's models, or switch what it serves (e.g. /swap flash)"),
        .init(usage: "/skills", summary: "List skills and what is selected for this chat"),
        .init(usage: "/skill <name>|new <what>", summary: "Select/deselect a skill for this chat, or have the model write a new one"),
        .init(usage: "/help", summary: "List commands"),
    ]

    public static func parse(_ raw: String) -> SlashCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let head = text.prefix { !$0.isWhitespace }
        let rest = text.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let arg: String? = rest.isEmpty ? nil : rest
        switch head.lowercased() {
        case "/compact", "/compress", "/summarize": return .compact(focus: arg)
        case "/goal": return .goal(rest)
        case "/think", "/thinking", "/effort", "/reasoning": return .think(arg)
        case "/context", "/ctx": return .context
        case "/swap", "/model", "/models", "/serve": return .swap(arg)
        case "/skills": return .skills
        case "/skill": return .skill(arg)
        case "/help", "/?", "/commands": return .help
        default: return nil
        }
    }
}

// MARK: - Goal mode

/// The protocol a `/goal` run speaks with the model: a kickoff message, a
/// continuation message each round, and two end markers the model writes on
/// a line of their own.
public enum GoalProtocol {
    public static let completeMarker = "GOAL_COMPLETE"
    public static let blockedMarker = "GOAL_BLOCKED"
    public static let defaultMaxRounds = 40

    public enum Status: Equatable, Sendable {
        case working
        case complete
        case blocked(String)
    }

    public static func kickoff(_ goal: String) -> String {
        """
        GOAL: \(goal)

        Work on this goal autonomously until it is completely done. Use your tools; plan with `todo_write` \
        for multi-step work; verify results (build, run, test, re-read files) instead of assuming.
        You will be prompted to continue after every reply, so it is fine to stop and resume in steps — \
        but do not stop to ask for confirmation of things you can decide or check yourself.

        When — and only when — the goal is fully achieved and verified, finish your reply with a line \
        containing exactly:
        \(completeMarker)
        If you genuinely cannot proceed without the user (missing credentials, a decision only they can make, \
        or an external blocker), finish with a line:
        \(blockedMarker): <what you need from the user>
        Never write either marker in any other situation.
        """
    }

    public static func continuation(_ goal: String, round: Int, maxRounds: Int, hitIterationLimit: Bool) -> String {
        let why = hitIterationLimit
            ? "You were cut off mid-work by the per-turn step limit. Pick up exactly where you left off."
            : "You have not declared the goal complete yet."
        return """
        [Goal round \(round) of \(maxRounds)] \(why)
        GOAL (unchanged): \(goal)

        Check what remains against the goal and continue. If everything is done, verify it one last time and \
        finish with a line `\(completeMarker)`. If you are blocked on the user, finish with \
        `\(blockedMarker): <what you need>`.
        """
    }

    /// Read the end marker from the model's final reply. Markers only count on
    /// a line of their own near the end, so the model explaining the protocol
    /// ("I'll write GOAL_COMPLETE when…") doesn't end the loop.
    public static func status(of reply: String) -> Status {
        let lines = reply.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t*`_#>-.!")) }
            .filter { !$0.isEmpty }
        for line in lines.suffix(3).reversed() {
            let upper = line.uppercased()
            if upper == completeMarker { return .complete }
            if upper.hasPrefix(blockedMarker) {
                let reason = line.dropFirst(blockedMarker.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": \t"))
                return .blocked(reason.isEmpty ? "The agent needs your input." : reason)
            }
        }
        return .working
    }
}
