import Foundation
import Observation
import DSHCore

/// A chat message in the transcript.
public struct MessageBody: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case user, assistant, notice, error }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// One tool call, from "started" through to its result.
public struct ToolActivity: Hashable, Sendable {
    public var name: String
    /// The interesting argument — a path, a command, a pattern.
    public var preview: String
    /// One-line headline of the result.
    public var summary: String?
    /// The full result, revealed on demand.
    public var output: String?
    /// nil while the call is still running.
    public var isOk: Bool?

    public var isFinished: Bool { isOk != nil }

    public init(name: String, preview: String, summary: String? = nil,
                output: String? = nil, isOk: Bool? = nil) {
        self.name = name
        self.preview = preview
        self.summary = summary
        self.output = output
        self.isOk = isOk
    }
}

/// One row of the transcript.
///
/// Messages, tool calls, and todo snapshots share one ordered list so a tool
/// call renders exactly where it happened — between the assistant text that
/// preceded it and the text that followed.
public struct ChatEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case message(MessageBody)
        case tool(ToolActivity)
        case todos([TodoItem])
    }

    public let id: String
    public var at: Date
    public var kind: Kind

    public init(id: String = UUID().uuidString, at: Date = .now, kind: Kind) {
        self.id = id
        self.at = at
        self.kind = kind
    }

    public var message: MessageBody? {
        if case .message(let body) = kind { return body }
        return nil
    }

    public var tool: ToolActivity? {
        if case .tool(let activity) = kind { return activity }
        return nil
    }
}

/// A pending permission question surfaced by the engine.
public struct GateVM: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// Observable state for one agent session, driven by `AppTransport`.
@MainActor
@Observable
public final class SessionVM: Identifiable {
    public let id: String
    public var title: String
    public var cwd: String?
    public var updatedAt: Date
    /// Pinned when the session is created, like the preset a chat runs under.
    public var preset: PermissionPreset

    public var entries: [ChatEntry] = []
    public var pendingGates: [GateVM] = []
    public var todos: [TodoItem] = []
    public var lastUsage: LLMUsage?
    /// Files this session's tools touched, newest first — shown as chips.
    public var changedFiles: [FileChange] = []

    public var running: Bool = false
    public var stopping: Bool = false
    /// Id of the assistant entry currently receiving streamed deltas.
    public var streamingID: String?

    public init(id: String, title: String, cwd: String?, preset: PermissionPreset = .workspaceWrite) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.preset = preset
        self.updatedAt = .now
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var workspaceURL: URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd)
    }

    public var projectName: String? {
        workspaceURL?.lastPathComponent
    }

    /// Tool calls still in flight — the composer shows what is happening.
    public var runningTool: ToolActivity? {
        for entry in entries.reversed() {
            if let tool = entry.tool, !tool.isFinished { return tool }
        }
        return nil
    }

    // MARK: - Mutation

    @discardableResult
    public func appendMessage(_ role: MessageBody.Role, _ text: String, at: Date = .now) -> String {
        let entry = ChatEntry(at: at, kind: .message(.init(role: role, text: text)))
        entries.append(entry)
        updatedAt = .now
        return entry.id
    }

    public func note(_ text: String, role: MessageBody.Role = .notice) {
        appendMessage(role, text)
    }

    /// Append streamed assistant text, opening a new bubble if none is live.
    public func appendDelta(_ chunk: String) {
        if let streamingID,
           let index = entries.lastIndex(where: { $0.id == streamingID }),
           case .message(var body) = entries[index].kind, body.role == .assistant {
            body.text += chunk
            entries[index].kind = .message(body)
        } else {
            streamingID = appendMessage(.assistant, chunk)
        }
        updatedAt = .now
    }

    /// Close the streaming bubble so the next text starts a fresh one (a tool
    /// call in between is what makes this matter).
    public func endStreaming() {
        if let streamingID,
           let index = entries.lastIndex(where: { $0.id == streamingID }),
           case .message(let body) = entries[index].kind,
           body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.remove(at: index)  // drop an empty bubble left by a tool-only turn
        }
        self.streamingID = nil
    }

    public func startTool(id: String, name: String, preview: String, at: Date = .now) {
        endStreaming()
        entries.append(ChatEntry(id: id, at: at, kind: .tool(.init(name: name, preview: preview))))
        updatedAt = .now
    }

    public func finishTool(id: String, ok: Bool, summary: String, output: String?) {
        guard let index = entries.lastIndex(where: { $0.id == id }),
              case .tool(var activity) = entries[index].kind else { return }
        activity.isOk = ok
        activity.summary = summary
        activity.output = output
        entries[index].kind = .tool(activity)
        updatedAt = .now
    }

    /// Record a completed tool in one step (used when replaying a stored log).
    public func addFinishedTool(id: String, name: String, preview: String,
                                summary: String?, output: String?, ok: Bool, at: Date) {
        entries.append(ChatEntry(id: id, at: at, kind: .tool(
            .init(name: name, preview: preview, summary: summary, output: output, isOk: ok)
        )))
    }

    public func setTodos(_ items: [TodoItem]) {
        todos = items
        // Keep one todo card, at the point the list last changed.
        entries.removeAll { if case .todos = $0.kind { return true } else { return false } }
        guard !items.isEmpty else { return }
        endStreaming()
        entries.append(ChatEntry(kind: .todos(items)))
        updatedAt = .now
    }

    public func recordFileChanges(_ changes: [FileChange]) {
        for change in changes {
            changedFiles.removeAll { $0.url == change.url }
            changedFiles.insert(change, at: 0)
        }
        if changedFiles.count > 40 { changedFiles = Array(changedFiles.prefix(40)) }
    }
}
