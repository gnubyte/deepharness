import Foundation
import SQLite3

/// One prompt the user sent, as recorded locally.
public struct PromptRecord: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let sessionId: String
    public let sessionTitle: String?
    public let cwd: String?
    public let sentAt: Date
    public let text: String
    public let attachmentCount: Int
    /// `queue` or `steer` — how it was submitted.
    public let mode: String

    public var isSteer: Bool { mode == "steer" }
}

/// Local, durable history of everything the user has typed.
///
/// This is the client's own record, deliberately independent of the harness:
/// session logs live in `DSH_HOME` and can be rotated, compacted, or deleted by
/// the harness, whereas this survives all of that and stays queryable across
/// every chat. It stores only what the user wrote — never model output, never
/// attachment bytes.
public actor PromptStore {
    private var db: OpaquePointer?
    public let url: URL

    /// `~/Library/Application Support/DSH` — the macOS equivalent of `%APPDATA%`.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("DSH", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(url: URL? = nil) throws {
        let resolved = try url ?? Self.defaultDirectory().appendingPathComponent("prompts.db")
        self.url = resolved
        // Opened before isolation is established: an actor's init cannot await
        // its own isolated methods, so the connection is prepared up front.
        self.db = try Self.openDatabase(at: resolved)
    }

    /// Close the connection. WAL checkpoints on close, so this is worth calling
    /// at shutdown rather than relying on process exit.
    public func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
            if let handle { sqlite3_close(handle) }
            throw PromptStoreError.cannotOpen(url.path, message)
        }
        // WAL keeps reads from blocking the write that records a prompt.
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        try migrate(handle)
        return handle
    }

    private static func migrate(_ handle: OpaquePointer?) throws {
        func run(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
                throw PromptStoreError.query(message)
            }
        }
        try run("""
        CREATE TABLE IF NOT EXISTS prompts (
          id                INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id        TEXT    NOT NULL,
          session_title     TEXT,
          cwd               TEXT,
          sent_at           REAL    NOT NULL,
          text              TEXT    NOT NULL,
          attachment_count  INTEGER NOT NULL DEFAULT 0,
          mode              TEXT    NOT NULL DEFAULT 'queue'
        );
        """)
        try run("CREATE INDEX IF NOT EXISTS idx_prompts_session ON prompts(session_id, sent_at DESC);")
        try run("CREATE INDEX IF NOT EXISTS idx_prompts_sent ON prompts(sent_at DESC);")
    }

    // MARK: - Writing

    /// Record one prompt. Failures are surfaced but never block sending.
    @discardableResult
    public func record(
        sessionId: String,
        sessionTitle: String?,
        cwd: String?,
        text: String,
        attachmentCount: Int,
        mode: String,
        at date: Date = Date()
    ) throws -> Int64 {
        let sql = """
        INSERT INTO prompts (session_id, session_title, cwd, sent_at, text, attachment_count, mode)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PromptStoreError.query(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, sessionId)
        bindText(stmt, 2, sessionTitle)
        bindText(stmt, 3, cwd)
        sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
        bindText(stmt, 5, text)
        sqlite3_bind_int(stmt, 6, Int32(attachmentCount))
        bindText(stmt, 7, mode)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PromptStoreError.query(lastMessage)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Keep the denormalised title current as the harness names a session.
    public func updateTitle(sessionId: String, title: String) throws {
        let sql = "UPDATE prompts SET session_title = ? WHERE session_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PromptStoreError.query(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, title)
        bindText(stmt, 2, sessionId)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PromptStoreError.query(lastMessage) }
    }

    // MARK: - Reading

    /// Prompts for one chat, newest first.
    public func prompts(sessionId: String, limit: Int = 500) throws -> [PromptRecord] {
        try select(
            "SELECT * FROM prompts WHERE session_id = ? ORDER BY sent_at DESC LIMIT ?;",
            bind: { stmt in
                self.bindText(stmt, 1, sessionId)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }
        )
    }

    /// Every prompt across every chat, newest first.
    public func recent(limit: Int = 500) throws -> [PromptRecord] {
        try select("SELECT * FROM prompts ORDER BY sent_at DESC LIMIT ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }
    }

    /// Substring search across every recorded prompt.
    ///
    /// A LIKE scan rather than an FTS index: this table holds one row per
    /// human prompt, so it stays small enough that literal substring matching
    /// is both fast and more predictable than token matching.
    public func search(_ query: String, limit: Int = 200) throws -> [PromptRecord] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try select(
            """
            SELECT * FROM prompts
            WHERE text LIKE ? ESCAPE '\\'
            ORDER BY sent_at DESC LIMIT ?;
            """,
            bind: { stmt in
                self.bindText(stmt, 1, "%\(escaped)%")
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }
        )
    }

    public func count() throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM prompts;", -1, &stmt, nil) == SQLITE_OK else {
            throw PromptStoreError.query(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Delete every prompt for one chat.
    public func deleteSession(_ sessionId: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM prompts WHERE session_id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            throw PromptStoreError.query(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sessionId)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw PromptStoreError.query(lastMessage) }
    }

    public func deleteAll() throws {
        try run("DELETE FROM prompts;")
    }

    // MARK: - Plumbing

    private func select(
        _ sql: String,
        bind: (OpaquePointer?) -> Void
    ) throws -> [PromptRecord] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PromptStoreError.query(lastMessage)
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var rows: [PromptRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(PromptRecord(
                id: sqlite3_column_int64(stmt, 0),
                sessionId: columnText(stmt, 1) ?? "",
                sessionTitle: columnText(stmt, 2),
                cwd: columnText(stmt, 3),
                sentAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                text: columnText(stmt, 5) ?? "",
                attachmentCount: Int(sqlite3_column_int(stmt, 6)),
                mode: columnText(stmt, 7) ?? "queue"
            ))
        }
        return rows
    }

    private func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw PromptStoreError.query(lastMessage)
        }
    }

    /// Best-effort pragma; a rejected pragma is a tuning miss, not a failure.
    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// SQLite keeps no copy of a bound string, so pass SQLITE_TRANSIENT.
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private var lastMessage: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
    }
}

public enum PromptStoreError: Error, LocalizedError {
    case cannotOpen(String, String)
    case query(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let message):
            return "Couldn’t open the prompt history at \(path): \(message)"
        case .query(let message):
            return "Prompt history query failed: \(message)"
        }
    }
}
