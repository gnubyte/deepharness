import Foundation

// MARK: - Queue log rendering
//
// Turns the raw task log into the "eloquent, easy to read, timestamped"
// report the user pulls up: a title, a stats line, then the lines grouped
// under their task.

public enum QueueLog {
    /// One task's section: header + its lines.
    public static func section(_ task: QueueTask, now: Date = .now) -> String {
        var out: [String] = []
        let mark = statusMark(task.status)
        out.append("\(mark) \(task.title)")
        out.append(metaLine(task, now: now))
        for line in task.log {
            out.append(format(line))
        }
        return out.joined(separator: "\n")
    }

    /// The whole queue, oldest activity first.
    public static func report(_ queue: TaskQueue, now: Date = .now) -> String {
        guard !queue.tasks.isEmpty else {
            return "The task queue is empty. Add a task to get started."
        }
        var out: [String] = []
        let s = queue.stats()
        var buckets: [String] = []
        if s.completed > 0 { buckets.append("\(s.completed) complete") }
        if s.running > 0 { buckets.append("\(s.running) running") }
        if s.queued > 0 { buckets.append("\(s.queued) queued") }
        if s.failed > 0 { buckets.append("\(s.failed) failed") }
        if s.blocked > 0 { buckets.append("\(s.blocked) blocked") }
        if s.total > 0 && (s.skipped > 0) { buckets.append("\(s.skipped) skipped") }
        out.append("\(queue.tasks.count) task\(queue.tasks.count == 1 ? "" : "s")"
            + (buckets.isEmpty ? " (none finished yet)" : " — " + buckets.joined(separator: ", ")))
        out.append("")
        // Show in queue order so the "long view" reads top to bottom.
        for task in queue.tasks {
            out.append(section(task, now: now))
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    public static func statusMark(_ status: QueueTaskStatus) -> String {
        switch status {
        case .complete: "✅"
        case .running: "▶️"
        case .queued: "•"
        case .blocked: "⏸"
        case .failed: "✖"
        case .skipped: "↦"
        }
    }

    private static func metaLine(_ task: QueueTask, now: Date) -> String {
        var parts: [String] = []
        parts.append("queued \(when(task.enteredAt, now: now))")
        if let started = task.startedAt {
            parts.append("started \(when(started, now: now))")
        }
        if let ended = task.finishedAt {
            let d = ended.timeIntervalSince(task.startedAt ?? ended)
            parts.append("finished \(when(ended, now: now)) (\(d.formattedDuration), \(task.rounds) rounds)")
        } else if task.status == .running, let started = task.startedAt {
            parts.append("running \(now.timeIntervalSince(started).formattedDuration)")
        }
        if task.totalTokens > 0 {
            parts.append("\(task.totalTokens.formatted()) tokens")
        }
        if let rate = task.avgTokensPerSecond {
            parts.append("\(Int(rate.rounded())) tokens/s avg")
        }
        return "  " + parts.joined(separator: " · ")
    }

    private static func format(_ line: QueueLogLine) -> String {
        "  \(when(line.at, now: Date.now))  \(line.text)"
    }

    /// Compact, readable relative timestamps: "now", "5m ago", "2h ago",
    /// "yesterday", then "Sep 24, 10:32" for anything older.
    public static func when(_ date: Date, now: Date = .now) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 45 { return "now" }
        let m = Int(secs) / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let days = h / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        let f = RelativeQueueDateFormatter()
        return f.string(from: date)
    }

    /// Absolute stamp for the raw log lines: "Sep 24, 10:32".
    private static func RelativeQueueDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }
}
