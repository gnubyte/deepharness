import Foundation
import Observation
import VisionHarnessCore

/// One chat in the archive, without its timeline.
struct ArchivedChat: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let project: String?
    let branch: String?
    let reason: String?
    let archivedAt: Date
    let updatedAt: Date
    let file: URL
}

/// Chats kept on disk after they leave the sidebar:
/// `~/Library/Application Support/DSHMac/archive/`, a JSON file per chat (the
/// same format as a live one) with a readable Markdown copy beside it.
@MainActor
@Observable
public final class ChatArchive {
    private(set) var chats: [ArchivedChat] = []
    let directory: URL

    /// The parts of a chat file the archive reads. `items` stays a raw value
    /// so reading can't lose fields, and writing back is byte-faithful enough.
    private struct File: Codable {
        struct Item: Codable {
            var kind: String
            var text: String?
            var toolName: String?
            var argSummary: String?
            var output: String?
            var at: Date?
        }
        var session: LogSession
        var items: [Item]
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    /// Read the index afresh. Off the main thread: an archive can get big.
    func reload() {
        let directory = directory
        Task.detached(priority: .utility) {
            let chats = Self.scan(directory)
            await MainActor.run { self.chats = chats }
        }
    }

    nonisolated private static func scan(_ directory: URL) -> [ArchivedChat] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url -> ArchivedChat? in
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
            return Self.row(file.session, url: url)
        }
        .sorted { $0.archivedAt > $1.archivedAt }
    }

    nonisolated private static func row(_ session: LogSession, url: URL) -> ArchivedChat {
        let projectPath = session.worktree?.repoPath ?? session.cwd
        return ArchivedChat(id: session.id, title: session.title,
                            project: projectPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                            branch: session.worktree?.branch, reason: session.archiveReason,
                            archivedAt: session.archivedAt ?? session.updatedAt,
                            updatedAt: session.updatedAt, file: url)
    }

    func archive(_ id: String, from log: ConversationLog, reason: String) {
        log.updateMeta(id) {
            $0.archivedAt = .now
            $0.archiveReason = reason
        }
        guard let source = log.releaseForArchive(id) else { return }
        let target = directory.appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: source, to: target)
            if let data = try? Data(contentsOf: target), let file = try? JSONDecoder().decode(File.self, from: data) {
                try? Self.markdown(file).write(to: target.deletingPathExtension().appendingPathExtension("md"),
                                               atomically: true, encoding: .utf8)
                chats.insert(Self.row(file.session, url: target), at: 0)
            }
        } catch {
            // The file stays with the live chats, so nothing is lost; it comes back next launch.
            _ = log.adopt(fileAt: source)
        }
    }

    /// Move a chat back. Returns its session row, repointed at the project
    /// when its worktree no longer exists.
    func restore(_ id: String, into log: ConversationLog) -> LogSession? {
        let source = directory.appendingPathComponent("\(id).json")
        let target = log.directory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: source), var file = try? JSONDecoder().decode(RawFile.self, from: data) else { return nil }
        file.session.archivedAt = nil
        file.session.archiveReason = nil
        if let worktree = file.session.worktree, !FileManager.default.fileExists(atPath: worktree.worktreePath) {
            file.session.cwd = worktree.repoPath
            file.session.worktree = nil
        }
        guard let updated = try? JSONEncoder().encode(file), (try? updated.write(to: target, options: .atomic)) != nil,
              let row = log.adopt(fileAt: target) else { return nil }
        removeFiles(id)
        chats.removeAll { $0.id == id }
        return row
    }

    /// Keeps every stored field when a restore edits the session.
    private struct RawFile: Codable {
        var session: LogSession
        var items: [JSONValue]
    }

    func deleteForever(_ id: String) {
        removeFiles(id)
        chats.removeAll { $0.id == id }
    }

    private func removeFiles(_ id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory.appendingPathComponent("\(id).json"))
        try? fm.removeItem(at: directory.appendingPathComponent("\(id).md"))
    }

    /// The readable transcript of an archived chat.
    nonisolated static func transcript(of chat: ArchivedChat) -> String {
        guard let data = try? Data(contentsOf: chat.file), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return "This chat's file couldn't be read: \(chat.file.path)"
        }
        return markdown(file)
    }

    /// Chats whose title or text contains every word of `query`.
    nonisolated static func search(_ query: String, in chats: [ArchivedChat]) -> [ArchivedChat] {
        chats.filter { chat in
            if ModelSearch.matches(query: query, fields: [chat.title, chat.project ?? "", chat.branch ?? ""]) { return true }
            guard let data = try? Data(contentsOf: chat.file), let file = try? JSONDecoder().decode(File.self, from: data) else { return false }
            return ModelSearch.matches(query: query, fields: file.items.compactMap(\.text))
        }
    }

    nonisolated private static func markdown(_ file: File) -> String {
        render(title: file.session.title, project: file.session.worktree?.repoPath ?? file.session.cwd,
               branch: file.session.worktree?.branch,
               rows: file.items.map { (kind: $0.kind, text: $0.text, tool: $0.toolName, args: $0.argSummary, output: $0.output) })
    }

    /// A chat as Markdown: the archive's copy, and what gets sent to Guardian.
    nonisolated static func render(title: String, project: String?, branch: String?,
                                   rows: [(kind: String, text: String?, tool: String?, args: String?, output: String?)]) -> String {
        var out = "# \(title)\n"
        if let project { out += "\nProject: `\(project)`" }
        if let branch { out += "\nBranch: `\(branch)`" }
        out += "\n"
        for row in rows {
            switch row.kind {
            case "user": out += "\n## You\n\n\(row.text ?? "")\n"
            case "assistant": out += "\n## Assistant\n\n\(row.text ?? "")\n"
            case "tool":
                out += "\n> Tool: `\(row.tool ?? "tool")` \(row.args ?? "")\n"
                if let summary = row.text, !summary.isEmpty { out += "> \(summary.replacingOccurrences(of: "\n", with: " "))\n" }
            case "compaction": out += "\n---\n\n*Earlier messages were summarized:*\n\n\(row.text ?? "")\n\n---\n"
            case "notice", "error": out += "\n*\(row.text ?? "")*\n"
            default: break
            }
        }
        return out
    }
}
