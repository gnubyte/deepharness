import Foundation
import VisionHarnessCore

/// A chat as the screenshot mode keeps it: every row in order with its time, tool cards with their results, and the
/// plan as it stood. A live run (`--snapshot-live`) writes one; the seeded chat is read from one.
struct SnapshotTranscript: Codable, Equatable {
    struct Todo: Codable, Equatable {
        var content: String
        var status: String
    }

    struct Row: Codable, Equatable {
        /// user | assistant | notice | error | tool | todos
        var kind: String
        /// Seconds after the chat's first row.
        var seconds: Double
        var text: String?
        var name: String?
        var preview: String?
        var summary: String?
        var output: String?
        var ok: Bool?
        var todos: [Todo]?
    }

    var title: String
    var model: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var contextUsed: Int?
    var rows: [Row]

    /// A tool's full output is kept up to this many characters (the card shows it when opened).
    static let outputLimit = 4_000

    init(title: String, model: String? = nil, promptTokens: Int? = nil, completionTokens: Int? = nil,
         contextUsed: Int? = nil, rows: [Row]) {
        self.title = title
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.contextUsed = contextUsed
        self.rows = rows
    }

    /// What a chat holds now.
    @MainActor
    init(from vm: SessionVM, started: Date, model: String? = nil) {
        let first = vm.entries.first?.at ?? started
        var rows: [Row] = []
        for entry in vm.entries {
            let seconds = max(0, (entry.at.timeIntervalSince(first) * 10).rounded() / 10)
            switch entry.kind {
            case .message(let body):
                rows.append(Row(kind: body.role.rawValue, seconds: seconds, text: body.text))
            case .tool(let tool):
                var output = tool.output
                if let full = output, full.count > Self.outputLimit {
                    output = String(full.prefix(Self.outputLimit)) + "\n…"
                }
                rows.append(Row(kind: "tool", seconds: seconds, name: tool.name, preview: tool.preview,
                                summary: tool.summary, output: output, ok: tool.isOk))
            case .todos(let items):
                rows.append(Row(kind: "todos", seconds: seconds,
                                todos: items.map { Todo(content: $0.content, status: $0.status.rawValue) }))
            case .compaction:
                break
            }
        }
        self.init(title: vm.title, model: model, promptTokens: vm.lastUsage?.promptTokens,
                  completionTokens: vm.lastUsage?.completionTokens, contextUsed: vm.contextUsed, rows: rows)
    }

    /// The rows as transcript entries, the first one at `start`.
    func entries(startingAt start: Date) -> [ChatEntry] {
        rows.enumerated().compactMap { index, row in
            let at = start.addingTimeInterval(row.seconds)
            let id = "snapshot-\(index)"
            switch row.kind {
            case "tool":
                return ChatEntry(id: id, at: at, kind: .tool(ToolActivity(
                    name: row.name ?? "tool", preview: row.preview ?? "", summary: row.summary,
                    output: row.output, isOk: row.ok ?? true)))
            case "todos":
                return ChatEntry(id: id, at: at, kind: .todos(Self.items(row.todos ?? [])))
            default:
                guard let role = MessageBody.Role(rawValue: row.kind) else { return nil }
                return ChatEntry(id: id, at: at, kind: .message(MessageBody(role: role, text: row.text ?? "")))
            }
        }
    }

    /// The plan as it stood at the end.
    var finalTodos: [TodoItem] {
        Self.items(rows.last { $0.kind == "todos" }?.todos ?? [])
    }

    /// How long the chat took, first row to last.
    var duration: TimeInterval { rows.last?.seconds ?? 0 }

    private static func items(_ todos: [Todo]) -> [TodoItem] {
        todos.enumerated().map { index, todo in
            TodoItem(id: String(index + 1), content: todo.content,
                     status: TodoItem.Status(rawValue: todo.status) ?? .pending)
        }
    }
}
