import Foundation

// MARK: - Task queue
//
// A durable, ordered list of autonomous work items. Each task is run exactly
// like a `/goal`: the harness works it round after round until the model
// declares it complete (or blocked / failed). Items are persisted as one
// JSON file so a week-long queue survives restarts, and every transition
// appends a timestamped log line so the whole run can be read afterwards.
//
// This type is pure Foundation — no UI, no transport — so the store logic
// (ordering, statuses, stats, persistence) is verifiable in tests.

public enum QueueTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case complete
    case blocked
    case failed
    case skipped

    public var label: String { rawValue.capitalized }
}

/// One line of a task's history.
public struct QueueLogLine: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var at: Date
    public var kind: Kind
    public var text: String

    public enum Kind: String, Codable, Sendable {
        case entered      // added to the queue
        case reordered    // moved in the queue
        case started      // work began
        case round        // a goal round finished
        case complete
        case blocked
        case failed
        case skipped
        case note         // free-form (edited, archived, …)
    }

    public init(id: UUID = UUID(), at: Date = .now, kind: Kind, text: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.text = text
    }
}

public struct QueueTask: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    /// Short human title ("Fix the login crash").
    public var title: String
    /// Full instructions; the goal text run with.
    public var details: String
    public var status: QueueTaskStatus
    public var enteredAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// How many goal rounds this task took.
    public var rounds: Int = 0
    /// Token totals for the whole task.
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    /// The session that worked this task (to jump to its transcript).
    public var sessionID: String?
    public var log: [QueueLogLine]

    public init(id: String = UUID().uuidString,
                title: String,
                details: String = "",
                status: QueueTaskStatus = .queued,
                enteredAt: Date = .now,
                log: [QueueLogLine] = []) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.enteredAt = enteredAt
        self.log = log
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? Date.now
        return max(0, end.timeIntervalSince(startedAt))
    }

    public var totalTokens: Int { promptTokens + completionTokens }

    /// Average tokens/second over the task's runtime (both directions, as the
    /// model server served them). Nil until the task has runtime.
    public var avgTokensPerSecond: Double? {
        guard let d = duration, d > 0, totalTokens > 0 else { return nil }
        return Double(totalTokens) / d
    }

    /// The text a goal loop runs for this task.
    public var goalText: String {
        details.isEmpty ? title : "\(title)\n\n\(details)"
    }

    public mutating func appendLog(_ kind: QueueLogLine.Kind, _ text: String, at: Date = .now) {
        log.append(QueueLogLine(at: at, kind: kind, text: text))
    }
}

/// A persistent, ordered queue of tasks.
public struct TaskQueue: Codable, Hashable, Sendable {
    public private(set) var tasks: [QueueTask]

    public init(tasks: [QueueTask] = []) {
        self.tasks = tasks
    }

    public subscript(id: String) -> QueueTask? {
        get { tasks.first { $0.id == id } }
        set {
            guard let task = newValue, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i] = task
        }
    }

    // MARK: Querying

    /// Append a fully-formed task (used by tests and restoration; the normal
    /// path is `add`, which logs the entry).
    public mutating func appendTask(_ task: QueueTask) { tasks.append(task) }

    public func task(_ id: String) -> QueueTask? { tasks.first { $0.id == id } }
    public func index(of id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    /// The next task to work: the first `.queued` item.
    public var nextTask: QueueTask? { tasks.first { $0.status == .queued } }

    public var runningTask: QueueTask? { tasks.first { $0.status == .running } }
    public var hasRunning: Bool { tasks.contains { $0.status == .running } }
    public var queuedCount: Int { tasks.count(where: { $0.status == .queued }) }
    public var completeCount: Int { tasks.count(where: { $0.status == .complete }) }

    /// All log lines across all tasks, oldest first — the queue's global log.
    public var allLogLines: [QueueLogLine] {
        tasks.flatMap { $0.log }.sorted { $0.at < $1.at }
    }
}

// MARK: - Stats

public struct QueueStats: Hashable, Sendable {
    public var total: Int
    public var completed: Int
    public var failed: Int
    public var blocked: Int
    public var running: Int
    public var queued: Int
    public var skipped: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalDuration: TimeInterval

    public var tokensPerSecond: Double? {
        totalDuration > 0 ? Double(completionTokens + promptTokens) / totalDuration : nil
    }

    public var finished: Bool { total > 0 && queued == 0 && running == 0 }
}

public extension TaskQueue {
    func stats() -> QueueStats {
        var s = QueueStats(total: tasks.count, completed: 0, failed: 0, blocked: 0,
                           running: 0, queued: 0, skipped: 0,
                           promptTokens: 0, completionTokens: 0, totalDuration: 0)
        for t in tasks {
            switch t.status {
            case .complete: s.completed += 1
            case .failed: s.failed += 1
            case .blocked: s.blocked += 1
            case .running: s.running += 1
            case .queued: s.queued += 1
            case .skipped: s.skipped += 1
            }
            s.promptTokens += t.promptTokens
            s.completionTokens += t.completionTokens
            if t.finishedAt != nil, let d = t.duration { s.totalDuration += d }
        }
        return s
    }
}

// MARK: - Mutations (used by the transport; keep the log consistent)

public extension TaskQueue {
    @discardableResult
    mutating func add(_ title: String, details: String = "", atFront: Bool = false) -> QueueTask {
        var task = QueueTask(title: title, details: details)
        task.appendLog(.entered, "Entered the queue at #\(atFront ? 1 : queuedCount + 1)")
        if atFront { tasks.insert(task, at: tasks.firstIndex { $0.status == .queued } ?? tasks.endIndex) }
        else { tasks.append(task) }
        return task
    }

    mutating func update(id: String, title: String?, details: String?) {
        guard var t = task(id) else { return }
        if let title, !title.isEmpty { t.title = title }
        if let details { t.details = details }
        t.appendLog(.note, "Details updated.")
        self[t.id] = t
    }

    mutating func remove(id: String) {
        guard let t = task(id) else { return }
        switch t.status {
        case .running:
            // Never lose the in-flight task's record; mark it instead.
            var marked = t
            marked.status = .skipped
            marked.finishedAt = .now
            marked.appendLog(.skipped, "Deleted while running — skipped.")
            self[t.id] = marked
        default:
            tasks.removeAll { $0.id == id }
        }
    }

    mutating func move(id: String, by offset: Int) {
        guard let from = index(of: id), tasks[from].status == .queued else { return }
        var to = from + offset
        // Keep the move inside the queued region.
        while to > 0 && tasks[to - 1].status != .queued { to -= 1 }
        while to < tasks.count - 1 && tasks[to + 1].status != .queued { to += 1 }
        guard to != from else { return }
        let t = tasks.remove(at: from)
        tasks.insert(t, at: to)
        if var moved = self[t.id] {
            moved.appendLog(.reordered, "Moved to position #\(position(of: t.id) ?? 0 + 1)")
            self[t.id] = moved
        }
    }

    mutating func move(id: String, before targetID: String?) {
        guard let from = index(of: id), tasks[from].status == .queued, from != 0 else { return }
        var to = targetID.flatMap(index(of:)) ?? tasks.count
        guard to != from else { return }
        if to > from { to -= 1 }
        let t = tasks.remove(at: from)
        tasks.insert(t, at: to)
        if var moved = self[t.id] {
            moved.appendLog(.reordered, "Moved to position #\(position(of: t.id) ?? 0 + 1)")
            self[t.id] = moved
        }
    }

    /// 1-based position among queued tasks (the "long view" number).
    public func position(of id: String) -> Int? {
        guard let idx = index(of: id) else { return nil }
        return tasks[0..<idx].count(where: { $0.status == .queued }) + 1
    }

    mutating func start(_ id: String) {
        // Queued, or a blocked/failed task being retried. Fresh stats each run.
        guard var t = task(id), t.status != .running else { return }
        t.status = .running
        t.startedAt = .now
        t.rounds = 0
        t.promptTokens = 0
        t.completionTokens = 0
        t.appendLog(.started, "Work started — \(t.title)")
        self[t.id] = t
    }

    /// Return a running task to the queue (the user stopped the run mid-way).
    mutating func markStopped(_ id: String, note: String = "Stopped by the user — back in the queue.") {
        guard var t = task(id), t.status == .running else { return }
        t.status = .queued
        t.startedAt = nil
        t.appendLog(.note, note)
        self[t.id] = t
    }

    /// Put a blocked/failed task back in line (optionally to the front so it's
    /// retried next), keeping its transcript link so work resumes in the same chat.
    mutating func requeue(_ id: String, toFront: Bool = true) {
        guard var t = task(id), t.status != .running else { return }
        let wasBlockedOrFailed = t.status == .blocked || t.status == .failed
        guard let at = index(of: id) else { return }
        t.status = .queued
        t.startedAt = nil
        if wasBlockedOrFailed { t.appendLog(.note, "Re-queued to retry.") }
        _ = tasks.remove(at: at)
        if toFront {
            let front = tasks.firstIndex { $0.status == .queued } ?? tasks.endIndex
            tasks.insert(t, at: front)
        } else {
            tasks.append(t)
        }
        self[id] = t
    }

    mutating func recordRound(_ id: String, round: Int, prompt: Int, completion: Int) {
        guard var t = task(id) else { return }
        t.rounds = round
        t.promptTokens += prompt
        t.completionTokens += completion
        self[t.id] = t
    }

    mutating func finish(_ id: String, status: QueueTaskStatus,
                         reason: String? = nil, sessionID: String? = nil) {
        guard var t = task(id) else { return }
        t.status = status
        t.finishedAt = .now
        if let sessionID { t.sessionID = sessionID }
        switch status {
        case .complete:
            let d = t.duration.map { "\($0.formattedDuration)" } ?? "?"
            let rate = t.avgTokensPerSecond.map { " · \(Int($0.rounded())) tokens/s avg" } ?? ""
            t.appendLog(.complete, "Complete after \(t.rounds) round\(t.rounds == 1 ? "" : "s"), \(d)\(rate).")
        case .blocked:
            t.appendLog(.blocked, "Blocked — \(reason ?? "needs the user").")
        case .failed:
            t.appendLog(.failed, "Failed — \(reason ?? "unknown error").")
        case .skipped:
            t.appendLog(.skipped, "Skipped.")
        default:
            break
        }
        self[t.id] = t
    }
}

public extension Double {
    /// 162.0 → "2m 42s"; 3600 → "1h 0m".
    var formattedDuration: String {
        let secs = Int(self.rounded())
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
    }
}
