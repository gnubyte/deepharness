import Foundation
import Observation

/// One stored transcript row.
public struct LogItemRow: Identifiable, Hashable, Sendable {
    public let sessionID: String
    public var seq: Int
    public var id: String { "\(sessionID):\(seq)" }
    /// user | assistant | tool | toolResult | notice | error
    public var kind: String
    public var text: String?
    public var toolName: String?
    public var argSummary: String?
    public var output: String?
    public var isError: Bool
    public var at: Date

    public init(sessionID: String, seq: Int, kind: String, text: String?,
                toolName: String?, argSummary: String?, output: String?,
                isError: Bool, at: Date) {
        self.sessionID = sessionID
        self.seq = seq
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.argSummary = argSummary
        self.output = output
        self.isError = isError
        self.at = at
    }
}

/// Stored session metadata.
public struct LogSession: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String?
    public var preset: String?
    public var updatedAt: Date
}

private struct StoredItem: Codable {
    var seq: Int
    var kind: String
    var text: String?
    var toolName: String?
    var argSummary: String?
    var output: String?
    var isError: Bool
    var at: Date
}

/// Per-session conversation store. One JSON file per session under
/// ~/Library/Application Support/DSHMac/conversations/.
@MainActor
public final class ConversationLog {
    public static let shared = ConversationLog()

    private let dir: URL
    private var rows: [String: LogSession] = [:]
    private var items: [String: [LogItemRow]] = [:]

    public init(dir: URL? = nil) {
        let base = dir ?? Self.defaultDir
        self.dir = base
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let fileManager = FileManager.default
            for url in (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
                where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let file = try? JSONDecoder().decode(SessionFile.self, from: data) {
                    rows[file.session.id] = file.session
                    items[file.session.id] = file.items.map {
                        LogItemRow(sessionID: file.session.id, seq: $0.seq, kind: $0.kind,
                                   text: $0.text, toolName: $0.toolName, argSummary: $0.argSummary,
                                   output: $0.output, isError: $0.isError, at: $0.at)
                    }
                }
            }
        } catch {}
    }

    static var defaultDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DSHMac", isDirectory: true)
                    .appendingPathComponent("conversations", isDirectory: true)
    }

    private func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    public func upsert(id: String, cwd: String?, title: String, preset: String?) {
        var row = rows[id] ?? LogSession(id: id, title: title, cwd: cwd, preset: preset, updatedAt: .now)
        row.title = title
        row.updatedAt = .now
        if let cwd, !cwd.isEmpty { row.cwd = cwd }
        if let preset { row.preset = preset }
        rows[id] = row
        persist(id)
    }

    public func list() -> [LogSession] {
        rows.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadItems(_ id: String) -> [LogItemRow] {
        items[id] ?? []
    }

    public func recordItem(_ id: String, kind: String, text: String?,
                           toolName: String?, argSummary: String?, output: String?,
                           isError: Bool) {
        var list = items[id, default: []]
        let row = LogItemRow(sessionID: id, seq: list.count, kind: kind, text: text,
                             toolName: toolName, argSummary: argSummary, output: output,
                             isError: isError, at: .now)
        list.append(row)
        items[id] = list
        persist(id)
    }

    public func delete(_ id: String) {
        rows[id] = nil
        items[id] = nil
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    public func touch(_ id: String) {
        guard var row = rows[id] else { return }
        row.updatedAt = .now
        rows[id] = row
        persist(id)
    }

    public func touch(_ id: String, title: String) {
        guard var row = rows[id] else { return }
        row.title = title
        row.updatedAt = .now
        rows[id] = row
        persist(id)
    }

    private func persist(_ id: String) {
        guard let row = rows[id] else { return }
        let file = SessionFile(session: row, items: (items[id] ?? []).map {
            StoredItem(seq: $0.seq, kind: $0.kind, text: $0.text, toolName: $0.toolName,
                       argSummary: $0.argSummary, output: $0.output, isError: $0.isError, at: $0.at)
        })
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL(id), options: .atomic)
    }

    private struct SessionFile: Codable {
        var session: LogSession
        var items: [StoredItem]
    }
}