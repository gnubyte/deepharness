import Foundation

/// One approval the agent is blocked on.
///
/// `rpcId` is the whole wire correlation — it is stable across replay, so a
/// client that reconnects mid-request answers the same id it first saw.
public struct PendingApproval: Identifiable, Sendable {
    public let rpcId: RpcId
    public let sessionId: String
    public let approvalId: String
    public let toolName: String
    public let callId: String?
    public let reason: String?

    public var id: String { approvalId }

    public init?(frame: Frame) {
        guard let sessionId = frame.sessionId,
              let approvalId = frame.payload["approvalId"]?.stringValue else { return nil }
        self.rpcId = frame.rpcId
        self.sessionId = sessionId
        self.approvalId = approvalId
        self.toolName = frame.payload["toolName"]?.stringValue ?? "tool"
        self.callId = frame.payload["callId"]?.stringValue
        self.reason = frame.payload["reason"]?.stringValue
    }
}

/// One option a question offers.
public struct QuestionOption: Identifiable, Hashable, Sendable {
    public let label: String
    public let description: String?
    public var id: String { label }
}

/// One question within a batch.
public struct QuestionItem: Identifiable, Sendable {
    public let id: String
    public let question: String
    public let detail: String?
    public let header: String?
    public let options: [QuestionOption]
    public let multiSelect: Bool
}

/// One `ask()` awaiting an answer.
///
/// Core models one ask as many questions and a single answer, so the whole
/// batch is answered together rather than one question at a time.
public struct PendingQuestions: Identifiable, Sendable {
    public let rpcId: RpcId
    public let sessionId: String
    public let items: [QuestionItem]

    public var id: String { rpcId.raw }

    public init?(frame: Frame) {
        guard let sessionId = frame.sessionId,
              let raw = frame.payload["questions"]?.arrayValue, !raw.isEmpty else { return nil }
        self.rpcId = frame.rpcId
        self.sessionId = sessionId
        self.items = raw.enumerated().compactMap { index, q in
            guard let text = q["question"]?.stringValue else { return nil }
            let options = (q["options"]?.arrayValue ?? []).compactMap { o -> QuestionOption? in
                guard let label = o["label"]?.stringValue else { return nil }
                return QuestionOption(label: label, description: o["description"]?.stringValue)
            }
            return QuestionItem(
                id: q["id"]?.stringValue ?? "q-\(index)",
                question: text,
                detail: q["detail"]?.stringValue,
                header: q["header"]?.stringValue,
                options: options,
                multiSelect: q["multiSelect"]?.boolValue ?? false
            )
        }
    }
}

/// One pending inbox occurrence from the authoritative `session/queue` snapshot.
public struct QueuedItem: Identifiable, Sendable {
    public enum Placement: String, Sendable {
        /// Renders in the queue dock.
        case queued
        /// Renders at the conversation tail.
        case steering
        /// Model-visible runtime context — never shown.
        case context
    }

    public let id: String
    public let placement: Placement
    public let text: String

    public init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue else { return nil }
        self.id = id
        self.placement = Placement(rawValue: value["placement"]?.stringValue ?? "") ?? .context
        let content = value.path("message", "content")?.arrayValue ?? []
        self.text = TranscriptAssembler.flattenText(content)
    }
}

/// One direct child in the subagent catalog.
public struct SubagentEntry: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// A healthy child; `mode` decides whether it can be prompted.
        case child(mode: String, label: String?, running: Bool, hasChildren: Bool)
        /// The catalog could read the row but not the child.
        case diagnostic(reason: String)
    }

    public let id: String
    public let kind: Kind

    public var isContinuable: Bool {
        if case .child(let mode, _, _, _) = kind { return mode == "continuable" }
        return false
    }

    public var running: Bool {
        if case .child(_, _, let running, _) = kind { return running }
        return false
    }

    public var title: String {
        switch kind {
        case .child(let mode, let label, _, _):
            return label ?? (mode == "one-shot" ? "One-shot subagent" : "Subagent")
        case .diagnostic(let reason):
            return "Unavailable (\(reason))"
        }
    }

    public init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue else { return nil }
        self.id = id
        switch value["kind"]?.stringValue {
        case "child":
            kind = .child(
                mode: value["mode"]?.stringValue ?? "one-shot",
                label: value["label"]?.stringValue,
                running: value["activity"]?.stringValue == "running",
                hasChildren: value["hasChildren"]?.boolValue ?? false
            )
        case "diagnostic":
            kind = .diagnostic(reason: value["reason"]?.stringValue ?? "unavailable")
        default:
            return nil
        }
    }
}

/// One workspace grouping sessions under a directory.
public struct Workspace: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let title: String
    public let sessionIds: [String]

    public init?(_ value: JSONValue) {
        guard let id = value["workspaceId"]?.stringValue else { return nil }
        self.id = id
        self.path = value["path"]?.stringValue ?? ""
        self.title = value["title"]?.stringValue ?? (path as NSString).lastPathComponent
        self.sessionIds = (value["sessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
    }
}

/// One search hit: a session plus an excerpt around the strongest match.
public struct SearchHit: Identifiable, Sendable {
    public let sessionId: String
    public let snippet: String
    public var id: String { sessionId }

    public init?(_ value: JSONValue) {
        guard let sessionId = value["sessionId"]?.stringValue else { return nil }
        self.sessionId = sessionId
        self.snippet = value["snippet"]?.stringValue ?? ""
    }
}
