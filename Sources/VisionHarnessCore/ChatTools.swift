import Foundation

// MARK: - Peer-chat tools
//
// The model can look into the harness's other chats: list what exists, and
// read one. This is how an agent avoids asking the user to re-paste context
// that another conversation already holds ("what did we decide about the
// signing config yesterday?"). Adjacent chats are read-only — a chat never
// writes into another.
//
// The app layer supplies the data (it owns the session list and the
// transcripts); the tools are thin shells over two snapshots.

/// One other chat as `list_chats` shows it.
public struct ChatSummary: Sendable {
    public let id: String
    public let title: String
    public let project: String?
    public let updatedAt: Date
    public let running: Bool
    /// The chat's most recent user or assistant text, one line.
    public let lastMessage: String?

    public init(id: String, title: String, project: String?, updatedAt: Date,
                running: Bool, lastMessage: String?) {
        self.id = id
        self.title = title
        self.project = project
        self.updatedAt = updatedAt
        self.running = running
        self.lastMessage = lastMessage
    }
}

/// A peer chat's transcript, flattened to text for `read_chat`.
public struct ChatTranscript: Sendable {
    public let id: String
    public let title: String
    public let messages: [(role: String, text: String)]

    public init(id: String, title: String, messages: [(role: String, text: String)]) {
        self.id = id
        self.title = title
        self.messages = messages
    }
}

/// The snapshots a chat tools instance reads. Value type so it is cheap to
/// build per turn and safe to hand to subagents.
public struct ChatDirectory: Sendable {
    public let chats: [ChatSummary]
    /// Reader for one chat's messages (nil = that chat is archived/unavailable).
    public let reader: @Sendable (String) -> ChatTranscript?

    public init(chats: [ChatSummary], reader: @escaping @Sendable (String) -> ChatTranscript?) {
        self.chats = chats
        self.reader = reader
    }

    public static let empty = ChatDirectory(chats: [], reader: { _ in nil })
}

/// A thread-safe holder for a ChatDirectory snapshot: the tools execute on a
/// pool thread while the app refreshes the snapshot (per turn, on the main
/// actor). The snapshot is at most one turn old — plenty for peering.
public final class ChatDirectoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ChatDirectory.empty

    public init() {}

    public func set(_ newValue: ChatDirectory) {
        lock.lock(); value = newValue; lock.unlock()
    }

    public func get() -> ChatDirectory {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// `list_chats`: the harness's other conversations.
public struct ListChatsTool: ToolExecutor {
    public static let name = "list_chats"
    public static let spec = ToolSpec(
        name: name,
        description: """
        List the harness's other chats (id, title, project, last activity). Use `read_chat` \
        with an id to see what one discussed — useful when context the user already gave \
        elsewhere would answer a question here. The current chat is excluded.
        """,
        parameters: """
        {"type":"object","properties":{
            "limit":{"type":"integer","description":"Max chats to list (default 30).","default":30}
        },"required":[]}
        """)

    public let directory: @Sendable () -> ChatDirectory

    public init(directory: @escaping @Sendable () -> ChatDirectory) {
        self.directory = directory
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let limit = Self.int(args, "limit", default: 30)
        let dir = directory()
        let current = context.workspace.path
        let rows = dir.chats
            .filter { !($0.project == current) || true }   // adjacent includes same-project chats
            .prefix(limit)
        guard !rows.isEmpty else {
            return ToolResult(output: "No other chats exist.")
        }
        var out = ["\(rows.count) other chat(s):"]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        for chat in rows {
            var line = "- [\(chat.id.prefix(8))] \(chat.title) — \(f.string(from: chat.updatedAt))\(chat.running ? " (running now)" : "")"
            if let project = chat.project { line += " · project: \(project)" }
            if let last = chat.lastMessage {
                line += "\n    last: \(String(last.prefix(140)))"
            }
            out.append(line)
        }
        return ToolResult(output: out.joined(separator: "\n"))
    }
}

/// `read_chat`: one adjacent conversation's transcript.
public struct ReadChatTool: ToolExecutor {
    public static let name = "read_chat"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Read another chat's transcript (the id's prefix from `list_chats` is enough). \
        Read-only: you cannot change another chat. Use it to pick up decisions, \
        file paths, or credentials context the user already established there.
        """,
        parameters: """
        {"type":"object","properties":{
            "id":{"type":"string","description":"The chat id (a unique prefix works)."},
            "last":{"type":"integer","description":"How many most-recent messages to return (default 40).","default":40}
        },"required":["id"]}
        """)

    public let directory: @Sendable () -> ChatDirectory

    public init(directory: @escaping @Sendable () -> ChatDirectory) {
        self.directory = directory
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let id = Self.string(args, "id") ?? ""
        let last = Self.int(args, "last", default: 40)
        guard !id.isEmpty else { return ToolResult(output: "Error: id is required.") }
        let dir = directory()
        // Prefix matching keeps the model's life simple ("read_chat id: 9f3a").
        let match = dir.chats.first { $0.id == id } ?? dir.chats.first { $0.id.hasPrefix(id) }
        guard let target = match else {
            let known = dir.chats.prefix(10).map { "[\($0.id.prefix(8))] \($0.title)" }.joined(separator: "\n")
            return ToolResult(output: "No chat matches \"\(id)\"." + (known.isEmpty ? "" : "\nKnown chats:\n\(known)"))
        }
        guard let transcript = dir.reader(target.id) else {
            return ToolResult(output: "Chat \"\(target.title)\" has no readable transcript (it may be archived).")
        }
        let chosen = Array(transcript.messages.suffix(max(1, last)))
        guard !chosen.isEmpty else { return ToolResult(output: "Chat \"\(target.title)\" is empty.") }
        var out = ["=== \"\(target.title)\" (\(transcript.messages.count) messages, showing last \(chosen.count)) ==="]
        for message in chosen {
            let text = message.text.replacingOccurrences(of: "\n", with: " ")
            out.append("[\(message.role)] \(String(text.prefix(600)))")
        }
        let joined = out.joined(separator: "\n")
        return ToolResult(output: String(joined.prefix(24_000)))
    }
}
