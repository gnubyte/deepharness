import Foundation

// MARK: - Token estimation
//
// Character-based (≈ 4 chars/token) — the standard heuristic when the server
// won't report prompt tokens. Good enough for budgeting; the exact figure
// arrives from `usage` the moment a real turn runs.

public enum TokenEstimate {
    /// Rough token count for one message: text + tool calls + attachment payloads.
    public static func message(_ m: LLMMessage) -> Int {
        var chars = m.content?.count ?? 0
        for call in m.toolCalls ?? [] {
            chars += call.name.count + call.arguments.raw.count
        }
        for att in m.attachments ?? [] {
            // Images are counted by their base64 payload, which is what the
            // model actually pays for.
            chars += att.data.base64EncodedString().count
        }
        return max(0, chars / 4)
    }

    /// Rough token count for a full request: system prompt + messages.
    public static func request(systemPrompt: String, messages: [LLMMessage]) -> Int {
        var total = systemPrompt.count / 4
        for m in messages { total += message(m) }
        return total
    }
}

// MARK: - Conversation compaction

/// When a transcript grows toward the model's context limit, the older part is
/// replaced by a summary the model writes, and the most recent messages are
/// kept verbatim. The plan and prompt builders here are pure and testable;
/// the summarizing LLM call lives in the app layer.
public enum Compaction {
    /// Compact once a request reaches this fraction of the window, so the next
    /// turn (prompt + output) still fits with headroom.
    public static let triggerFraction: Double = 0.75
    /// Keep this fraction of the window of recent conversation verbatim.
    public static let keepFraction: Double = 0.25
    /// Even for small windows, keep at least this much recent context.
    public static let minKeepTokens = 4_000
    /// Summarizing fewer than this many messages is not worth the round trip.
    public static let minSummarizable = 4

    /// Prepend this to a compacted transcript's summary message so the model
    /// (and a human reading it back from storage) knows what it is.
    public static let summaryHeader = "[Earlier conversation, compacted]\n"

    public struct Plan {
        /// The older messages to summarize (a complete conversation: ends before
        /// a user turn, so no tool result is left orphaned).
        public let toSummarize: [LLMMessage]
        /// The recent tail to keep verbatim; always starts with a user message.
        public let toKeep: [LLMMessage]
        /// The request size that triggered compaction.
        public let usedTokens: Int
        /// The window limit compaction is budgeted against.
        public let limit: Int
    }

    /// A compaction plan when the request is over budget and the transcript can
    /// actually be split; `nil` otherwise (under the trigger, or nothing old
    /// enough to summarize).
    ///
    /// The split lands on a user-message boundary: everything before it is a
    /// finished conversation (each assistant tool-call answered by its tool
    /// result), and the kept tail begins where the user spoke again.
    public static func plan(usedTokens: Int, limit: Int, transcript: [LLMMessage]) -> Plan? {
        guard limit > 0, !transcript.isEmpty else { return nil }
        let threshold = Int(Double(limit) * triggerFraction)
        guard usedTokens >= threshold else { return nil }

        let keepBudget = max(Int(Double(limit) * keepFraction), minKeepTokens)
        var tokens = 0
        var boundary: Int? = nil
        var i = transcript.count - 1
        while i >= 0 {
            let m = transcript[i]
            tokens += TokenEstimate.message(m)
            if m.role == .user { boundary = i }
            if tokens >= keepBudget { break }
            i -= 1
        }
        guard let boundary, boundary > 0 else { return nil }
        let toSummarize = Array(transcript[0..<boundary])
        let toKeep = Array(transcript[boundary...])
        guard toSummarize.count >= minSummarizable else { return nil }
        return Plan(toSummarize: toSummarize, toKeep: toKeep, usedTokens: usedTokens, limit: limit)
    }

    /// The prompt that turns `messages` into a continuity summary.
    ///
    /// Each message is capped at a share of `budgetTokens` (in characters) so
    /// the summarizing request itself fits comfortably inside the window even
    /// when it is asking about a transcript that nearly filled it.
    public static func summaryPrompt(for messages: [LLMMessage], budgetTokens: Int) -> String {
        let perMessage = max(300, budgetTokens * 4 / max(1, messages.count))
        var body = ""
        for m in messages {
            switch m.role {
            case .system:
                body += "System: \(clip(m.content ?? "", perMessage / 4))\n"
            case .user:
                body += "User: \(clip(m.content ?? "", perMessage))\n"
            case .assistant:
                body += "Assistant: \(clip(m.content ?? "", perMessage))"
                for call in m.toolCalls ?? [] {
                    body += " [tool call: \(call.name) \(clip(call.arguments.raw, perMessage / 3))]"
                }
                body += "\n"
            case .tool:
                body += "Tool result (\(m.name ?? "unknown")): \(clip(m.content ?? "", perMessage / 2))\n"
            }
        }
        return """
        The earlier part of this agent conversation was compacted to fit the context window. \
        Write a continuity note the agent can pick up from, in at most ~500 words, with these sections:

        - Task: what the user asked for and the current goal
        - Decisions: important choices, constraints, and why
        - Work done: files created/edited (with paths), commands run, key results
        - Open items: unfinished steps, unresolved errors, pending questions
        - State: exactly where the conversation stands now

        Be factual and specific (paths, commands, versions, error messages). Omit small talk.

        <conversation>
        \(body)
        </conversation>
        """
    }

    private static func clip(_ s: String, _ maxChars: Int) -> String {
        s.count <= maxChars ? s : String(s.suffix(maxChars)) + " …[truncated]"
    }
}
