import Foundation

/// How full the model's context window is.
///
/// The harness computes this host-side and pushes it as a projection, so the
/// client never re-derives token counts from the transcript.
public struct ContextPressure: Sendable, Equatable {
    /// Tokens already committed to the request prefix.
    public let pressureTokens: Int
    /// Pressure plus what the pending turn is expected to add.
    public let projectedTokens: Int
    /// Capacity of the current route's model.
    public let contextWindow: Int

    public init?(_ value: JSONValue?) {
        guard let value,
              let window = value["contextWindow"]?.intValue, window > 0 else { return nil }
        self.pressureTokens = value["pressureTokens"]?.intValue ?? 0
        self.projectedTokens = value["projectedTokens"]?.intValue ?? 0
        self.contextWindow = window
    }

    /// Committed share of the window, 0…1.
    public var usedFraction: Double {
        min(1, max(0, Double(pressureTokens) / Double(contextWindow)))
    }

    /// Projected share, which may exceed the committed share mid-turn.
    public var projectedFraction: Double {
        min(1, max(0, Double(projectedTokens) / Double(contextWindow)))
    }

    public var remainingTokens: Int { max(0, contextWindow - pressureTokens) }

    /// Compaction becomes likely as this climbs; the thresholds are the
    /// client's own presentation choice, not a harness contract.
    public enum Level: Sendable { case comfortable, tight, critical }

    public var level: Level {
        switch projectedFraction {
        case ..<0.7: .comfortable
        case ..<0.9: .tight
        default: .critical
        }
    }
}

/// What is occupying the context window.
public struct ContextBreakdown: Sendable, Equatable {
    public let systemTokens: Int
    public let toolsTokens: Int
    public let messageTokens: Int

    public init?(_ value: JSONValue?) {
        guard let value else { return nil }
        let system = value["systemTokens"]?.intValue
        let tools = value["toolsTokens"]?.intValue
        let messages = value["messageTokens"]?.intValue
        guard system != nil || tools != nil || messages != nil else { return nil }
        self.systemTokens = system ?? 0
        self.toolsTokens = tools ?? 0
        self.messageTokens = messages ?? 0
    }

    public var total: Int { systemTokens + toolsTokens + messageTokens }
}

/// Cumulative token spend for the session.
public struct TokenUsage: Sendable, Equatable {
    public let uncachedInputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int

    public init?(_ value: JSONValue?) {
        guard let value else { return nil }
        self.uncachedInputTokens = value["uncachedInputTokens"]?.intValue ?? 0
        self.outputTokens = value["outputTokens"]?.intValue ?? 0
        self.cacheReadTokens = value["cacheReadTokens"]?.intValue ?? 0
        self.cacheWriteTokens = value["cacheWriteTokens"]?.intValue ?? 0
    }

    /// Everything sent, cached or not.
    public var totalInput: Int { uncachedInputTokens + cacheReadTokens }
}

/// Turn and timing counters for the session.
public struct SessionStats: Sendable, Equatable {
    public let turns: Int
    public let steps: Int
    public let llmMs: Int
    public let toolMs: Int
    /// Time to first token on the most recent turn.
    public let ttftMs: Int
    public let decodeMs: Int
    public let decodeTokens: Int

    public init?(_ value: JSONValue?) {
        guard let value else { return nil }
        self.turns = value["turns"]?.intValue ?? 0
        self.steps = value["steps"]?.intValue ?? 0
        self.llmMs = value["llmMs"]?.intValue ?? 0
        self.toolMs = value["toolMs"]?.intValue ?? 0
        self.ttftMs = value["ttftMs"]?.intValue ?? 0
        self.decodeMs = value["decodeMs"]?.intValue ?? 0
        self.decodeTokens = value["decodeTokens"]?.intValue ?? 0
    }

    /// Output tokens per second while decoding, when there is enough signal.
    public var tokensPerSecond: Double? {
        guard decodeMs > 0, decodeTokens > 0 else { return nil }
        return Double(decodeTokens) / (Double(decodeMs) / 1000)
    }
}

/// The permission preset a session runs under.
public struct PermissionState: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public let value: String
        public let name: String
        public var id: String { value }

        /// `workspace-write` → `Workspace Write`.
        public var displayName: String {
            name.split(separator: "-").map(\.capitalized).joined(separator: " ")
        }
    }

    public let options: [Option]
    public let currentValue: String

    public init?(_ value: JSONValue?) {
        guard let value, let current = value["currentValue"]?.stringValue else { return nil }
        self.currentValue = current
        self.options = (value["options"]?.arrayValue ?? []).compactMap { o in
            guard let v = o["value"]?.stringValue else { return nil }
            return Option(value: v, name: o["name"]?.stringValue ?? v)
        }
    }

    /// The preset that removes the sandbox and stops asking for approval.
    public static let fullAccess = "danger-full-access"

    public var isFullAccess: Bool { currentValue == Self.fullAccess }

    public var displayName: String {
        options.first { $0.value == currentValue }?.displayName
            ?? currentValue.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }
}

/// Format a token count compactly for a status line.
public func formatTokens(_ count: Int) -> String {
    switch count {
    case ..<1_000: "\(count)"
    case ..<10_000: String(format: "%.1fk", Double(count) / 1_000)
    case ..<1_000_000: "\(count / 1_000)k"
    default: String(format: "%.1fM", Double(count) / 1_000_000)
    }
}
