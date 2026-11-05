import Foundation

// MARK: - Automations (scheduled prompts)
//
// A third mode next to Chats and Code: named, scheduled prompts that run
// unattended in their own chat — "run the ticket sync every weekday at 8:30",
// "check the build on Monday". The schedule engine is pure Foundation so the
// next-run math is testable; the app layer owns the timer and the runner.
//
// OpenClaw compatibility: OpenClaw (the user's other agent) keeps scheduled
// tasks as `jobs.json` with cron/interval/one-off schedules. This file reads
// and writes that format (`OpenClawCompat`), so an automation library built
// here round-trips through OpenClaw and vice versa.

/// A scheduled prompt the harness runs in its own chat.
public struct Automation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The prompt text the automation sends (an unattended goal).
    public var prompt: String
    public var schedule: AutomationSchedule
    public var enabled: Bool
    public var createdAt: Date
    /// The project folder it runs in (nil = the harness's current project).
    public var projectPath: String?
    /// Optional cap on one run, in seconds (nil = the harness default).
    public var timeoutSeconds: Int?
    /// Last-run bookkeeping.
    public var lastRunAt: Date?
    public var lastStatus: String?
    public var lastDuration: TimeInterval?
    public var runCount: Int
    /// The chat the last run used (so "open its chat" works).
    public var sessionID: String?
    public var history: [AutomationRun]
    /// Files/images the automation sends with its prompt (a spec, a screenshot).
    public var attachments: [MessageAttachment]?

    public init(id: String = UUID().uuidString, name: String, prompt: String,
                schedule: AutomationSchedule, enabled: Bool = true, createdAt: Date = .now,
                projectPath: String? = nil, timeoutSeconds: Int? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.enabled = enabled
        self.createdAt = createdAt
        self.projectPath = projectPath
        self.timeoutSeconds = timeoutSeconds
        self.runCount = 0
        self.history = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, schedule, enabled, createdAt, projectPath, timeoutSeconds
        case lastRunAt, lastStatus, lastDuration, runCount, sessionID, history, attachments
    }

    /// Tolerant decoding: a file written by an older or newer build still
    /// loads — missing fields take their defaults rather than failing the
    /// whole library.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        schedule = try c.decodeIfPresent(AutomationSchedule.self, forKey: .schedule) ?? .cron(expr: "* * * * *", timeZone: TimeZone.current.identifier)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .lastDuration)
        runCount = try c.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        history = (try? c.decodeIfPresent([AutomationRun].self, forKey: .history)) ?? []
        attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments)
    }

    /// One entry in the run log.
    public struct Run: Codable, Hashable, Sendable {
        public var at: Date
        public var status: String
        public var duration: TimeInterval?
        public var sessionID: String?
        public var detail: String?

        public init(at: Date = .now, status: String, duration: TimeInterval? = nil,
                    sessionID: String? = nil, detail: String? = nil) {
            self.at = at
            self.status = status
            self.duration = duration
            self.sessionID = sessionID
            self.detail = detail
        }
    }
}

/// Alias so call sites read naturally; `Automation.Run` is the canonical name.
public typealias AutomationRun = Automation.Run

/// When an automation fires. Cron uses vixie-cron day semantics; interval is
/// a fixed period; once is a single moment (auto-disabling after it runs).
public enum AutomationSchedule: Hashable, Sendable {
    case cron(expr: String, timeZone: String)
    case interval(seconds: Int, anchor: Date?)
    case once(at: Date)

    public var label: String {
        switch self {
        case .cron(let expr, let tz):
            let described = CronParser.describe(expr)
            return described == expr ? expr : "\(described) (\(tz))"
        case .interval(let seconds, _):
            if seconds % 3600 == 0 { return "Every \(seconds / 3600)h" }
            if seconds % 60 == 0 { return "Every \(seconds / 60) min" }
            return "Every \(seconds)s"
        case .once(let at):
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return "Once — \(f.string(from: at))"
        }
    }

    public var timeZoneName: String? {
        if case .cron(_, let tz) = self { return tz }
        return nil
    }
}

extension AutomationSchedule: Codable {
    private enum CodingKeys: String, CodingKey { case kind, expr, tz, seconds, everyMs, anchor, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        switch kind {
        case "cron":
            self = .cron(expr: (try? c.decode(String.self, forKey: .expr)) ?? "* * * * *",
                         timeZone: (try? c.decode(String.self, forKey: .tz)) ?? TimeZone.current.identifier)
        case "every", "interval":
            let ms = (try? c.decode(Int.self, forKey: .everyMs)) ?? nil
            let secs = (try? c.decode(Int.self, forKey: .seconds)) ?? nil
            let total = ms.map { $0 / 1000 } ?? secs ?? 300
            let anchorMs = (try? c.decode(Double.self, forKey: .anchor)) ?? nil
            let anchor = anchorMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            self = .interval(seconds: max(1, total), anchor: anchor)
        case "at", "once":
            // OpenClaw stores an ISO-8601 instant; accept epoch seconds too.
            if let s = try? c.decode(String.self, forKey: .at) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: s) { self = .once(at: d); return }
                iso.formatOptions = [.withInternetDateTime]
                if let d = iso.date(from: s) { self = .once(at: d); return }
                if let t = TimeInterval(s) { self = .once(at: Date(timeIntervalSince1970: t)); return }
                self = .once(at: Date())
            } else if let ms = try? c.decode(Double.self, forKey: .at) {
                self = .once(at: Date(timeIntervalSince1970: ms / (ms > 1e12 ? 1000 : 1)))
            } else {
                self = .once(at: Date())
            }
        default:
            self = .cron(expr: "* * * * *", timeZone: TimeZone.current.identifier)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cron(let expr, let tz):
            try c.encode("cron", forKey: .kind)
            try c.encode(expr, forKey: .expr)
            try c.encode(tz, forKey: .tz)
        case .interval(let seconds, let anchor):
            try c.encode("every", forKey: .kind)
            try c.encode(seconds * 1000, forKey: .everyMs)
            if let anchor { try c.encode(anchor.timeIntervalSince1970 * 1000, forKey: .anchor) }
        case .once(let at):
            try c.encode("at", forKey: .kind)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(f.string(from: at), forKey: .at)
        }
    }
}

// MARK: - Cron

/// A small, strict-enough 5-field cron parser: `minute hour dom month dow`
/// with `*`, `*/n`, lists `a,b`, and ranges `a-b`. Day matching follows
/// vixie-cron: when both day-of-month and day-of-week are restricted, a day
/// matches when EITHER matches.
public enum CronParser {
    public static func isValid(_ expr: String) -> Bool {
        next(after: Date(), expr: expr, timeZone: TimeZone.current.identifier) != nil || fields(expr) != nil
    }

    /// The next time strictly after `date` matching `expr`, in `timeZone`.
    /// Returns nil for an invalid expression or when nothing matches within
    /// ~4 years (a `Feb 30`-style expression).
    public static func next(after date: Date, expr: String, timeZone: String) -> Date? {
        guard let f = fields(expr) else { return nil }
        guard let tz = TimeZone(identifier: timeZone) ?? TimeZone(identifier: "UTC") else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // Start at the next whole minute after `date`.
        var minuteComponent = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        minuteComponent.minute! += 1
        guard var cursor = cal.date(from: minuteComponent) else { return nil }

        let deadline = date.addingTimeInterval(366 * 86400 * 4)
        while cursor < deadline {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: cursor)
            guard let year = c.year, let month = c.month, let day = c.day,
                  let hour = c.hour, let minute = c.minute, let weekday = c.weekday else { return nil }
            // Cron's dow: 0=Sunday. Calendar's: 1=Sunday.
            let cronDow = weekday - 1

            func atMidnight(_ nextDay: Int, _ nextMonth: Int, _ nextYear: Int) -> Date {
                var dc = DateComponents()
                dc.year = nextYear; dc.month = nextMonth; dc.day = nextDay
                dc.hour = 0; dc.minute = 0
                return cal.date(from: dc) ?? cursor.addingTimeInterval(86400)
            }

            // Month out of the set: jump to the 1st of the next month, 00:00.
            // (The loop re-checks; a sparse months set walks at most 48 jumps
            // before the deadline check ends it.)
            guard f.months.contains(month) else {
                cursor = atMidnight(1, month + 1, year)
                continue
            }
            // Day matching follows vixie-cron: both restricted → OR.
            let domRestricted = f.rawDom != "*"
            let dowRestricted = f.rawDow != "*"
            let dayOk: Bool
            if domRestricted && dowRestricted {
                dayOk = f.daysOfMonth.contains(day) || f.daysOfWeek.contains(cronDow)
            } else if domRestricted {
                dayOk = f.daysOfMonth.contains(day)
            } else if dowRestricted {
                dayOk = f.daysOfWeek.contains(cronDow)
            } else {
                dayOk = true
            }
            guard dayOk else {
                cursor = atMidnight(day + 1, month, year)
                continue
            }
            guard f.hours.contains(hour) else {
                // `.min()` — a Set's order is arbitrary, and "the next hour"
                // must be the smallest one still ahead.
                if let later = f.hours.filter({ $0 > hour }).min() {
                    var dc = DateComponents()
                    dc.year = year; dc.month = month; dc.day = day
                    dc.hour = later; dc.minute = 0
                    cursor = cal.date(from: dc) ?? cursor.addingTimeInterval(3600)
                } else {
                    cursor = atMidnight(day + 1, month, year)
                }
                continue
            }
            guard f.minutes.contains(minute) else {
                if let later = f.minutes.filter({ $0 > minute }).min() {
                    var dc = DateComponents()
                    dc.year = year; dc.month = month; dc.day = day
                    dc.hour = hour; dc.minute = later
                    cursor = cal.date(from: dc) ?? cursor.addingTimeInterval(60)
                } else {
                    var dc = DateComponents()
                    dc.year = year; dc.month = month; dc.day = day
                    dc.hour = hour + 1; dc.minute = 0
                    cursor = cal.date(from: dc) ?? cursor.addingTimeInterval(3600)
                }
                continue
            }
            return cursor
        }
        return nil
    }

    /// "Every day at 08:30"-style description. Falls back to the expression
    /// itself when it doesn't fit a friendly pattern.
    public static func describe(_ expr: String) -> String {
        guard let f = fields(expr) else { return expr }
        let everyMinute = f.rawMinute.contains("*/") || f.rawMinute == "*"
        let everyHour = f.rawHour.contains("*/") || f.rawHour == "*"
        let everyDay = f.rawDom == "*" && f.rawDow == "*"
        let everyMonth = f.rawMonth == "*"

        if everyMinute && everyHour && everyDay && everyMonth {
            return "Every minute"
        }
        if !everyMinute && everyHour {
            let times = f.minutes.sorted().map { String($0) }.joined(separator: ", ")
            return "Hourly at minute \(times)"
        }
        let dayName: String
        if everyDay {
            dayName = everyMonth ? "every day" : "on month \(f.months.sorted().map(String.init).joined(separator: ","))"
        } else if f.rawDow != "*" {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let dows = f.daysOfWeek.sorted().map { names[$0] }.joined(separator: ", ")
            dayName = "on \(dows)"
        } else {
            dayName = "on day \(f.daysOfMonth.sorted().map(String.init).joined(separator: ","))"
        }
        if everyHour { return "\(dayName) hourly" }
        let clock = f.hours.sorted().map { h in
            f.minutes.sorted().map { String(format: "%02d:%02d", h, $0) }.joined(separator: ", ")
        }.joined(separator: ", ")
        return "\(dayName) at \(clock)"
    }

    // MARK: Field model

    struct Fields {
        var minutes: Set<Int>
        var hours: Set<Int>
        var daysOfMonth: Set<Int>
        var months: Set<Int>
        var daysOfWeek: Set<Int>
        var rawMinute: String
        var rawHour: String
        var rawDom: String
        var rawMonth: String
        var rawDow: String
    }

    static func fields(_ expr: String) -> Fields? {
        let parts = expr.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return nil }
        guard let minutes = set(parts[0], 0...59),
              let hours = set(parts[1], 0...23),
              let dom = set(parts[2], 1...31),
              let months = set(parts[3], 1...12),
              let dow = set(parts[4], 0...6) else { return nil }
        return Fields(minutes: minutes, hours: hours, daysOfMonth: dom, months: months, daysOfWeek: dow,
                      rawMinute: parts[0], rawHour: parts[1], rawDom: parts[2], rawMonth: parts[3], rawDow: parts[4])
    }

    /// One cron field → the set of values it names. `*`, `*/n`, `a`, `a-b`,
    /// `a-b/n`, `a,b-c,*/2` all parse; anything else fails the field.
    private static func set(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out: Set<Int> = []
        for piece in field.split(separator: ",") {
            let p = String(piece)
            if p == "*" {
                out.formUnion(Range(uncheckedBounds: (range.lowerBound, range.upperBound + 1)))
                continue
            }
            if p.hasPrefix("*/") {
                guard let step = Int(p.dropFirst(2)), step > 0 else { return nil }
                var v = range.lowerBound
                while v <= range.upperBound { out.insert(v); v += step }
                continue
            }
            if p.contains("-") {
                let bounds = p.split(separator: "-").map(String.init)
                guard bounds.count == 2, let lo = Int(bounds[0]) else { return nil }
                var hiStr = bounds[1]
                var step = 1
                if let slash = hiStr.firstIndex(of: "/") {
                    guard let s = Int(hiStr[hiStr.index(after: slash)...]), s > 0 else { return nil }
                    step = s
                    hiStr = String(hiStr[..<slash])
                }
                guard let hi = Int(hiStr), lo <= hi else { return nil }
                var v = lo
                while v <= min(hi, range.upperBound) { out.insert(v); v += step }
                continue
            }
            if p.contains("/") {
                let halves = p.split(separator: "/").map(String.init)
                guard halves.count == 2, let lo = Int(halves[0]), let step = Int(halves[1]), step > 0 else { return nil }
                var v = lo
                while v <= range.upperBound { out.insert(v); v += step }
                continue
            }
            guard let v = Int(p), range.contains(v) else { return nil }
            out.insert(v)
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Next-run resolution

public enum AutomationNext {
    /// The next fire time strictly after `date`, or nil (invalid/never again).
    public static func next(_ schedule: AutomationSchedule, after date: Date) -> Date? {
        switch schedule {
        case .cron(let expr, let tz):
            return CronParser.next(after: date, expr: expr, timeZone: tz)
        case .interval(let seconds, let anchor):
            let base = anchor ?? date
            let period = TimeInterval(max(1, seconds))
            guard base <= date else { return base }
            let elapsed = date.timeIntervalSince(base)
            let periods = (elapsed / period).rounded(.down) + 1
            return base.addingTimeInterval(periods * period)
        case .once(let at):
            return at > date ? at : nil
        }
    }
}

// MARK: - Store

/// The automation list plus its persistence. Pure logic — the file location is
/// the caller's choice (tests use a temp dir).
public struct AutomationStore: Codable, Sendable {
    public private(set) var automations: [Automation]

    public init(automations: [Automation] = []) {
        self.automations = automations
    }

    private enum CodingKeys: String, CodingKey { case automations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automations = (try? c.decode([Automation].self, forKey: .automations)) ?? []
    }

    public func automation(id: String) -> Automation? { automations.first { $0.id == id } }

    public mutating func add(_ automation: Automation) {
        automations.insert(automation, at: 0)
    }

    public mutating func update(_ automation: Automation) {
        guard let i = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        automations[i] = automation
    }

    public mutating func remove(id: String) {
        automations.removeAll { $0.id == id }
    }

    public mutating func toggle(id: String) {
        guard var a = automation(id: id) else { return }
        a.enabled.toggle()
        update(a)
    }

    /// Record a finished run: bookkeeping + a history line (capped at 50).
    /// A `.once` schedule disables itself after its run — it is done.
    public mutating func recordRun(id: String, at: Date = .now, status: String,
                                   duration: TimeInterval?, sessionID: String?, detail: String?) {
        guard var a = automation(id: id) else { return }
        a.lastRunAt = at
        a.lastStatus = status
        a.lastDuration = duration
        a.runCount += 1
        a.sessionID = sessionID
        a.history.append(Automation.Run(at: at, status: status, duration: duration,
                                        sessionID: sessionID, detail: detail))
        if a.history.count > 50 { a.history = Array(a.history.suffix(50)) }
        if case .once = a.schedule { a.enabled = false }
        update(a)
    }
}

// MARK: - Persistence

public enum AutomationFile {
    /// Load the store; nil (not an error) when the file doesn't exist yet.
    public static func load(from url: URL) -> AutomationStore? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(AutomationStore.self, from: data)
        } catch {
            // One bad record must not cost the whole library: salvage the
            // records that decode by pulling the raw array back out.
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let automations = obj as? [String: Any],
                  let list = automations["automations"] as? [[String: Any]] else { return nil }
            var good: [Automation] = []
            for element in list where JSONSerialization.isValidJSONObject(element) {
                if let record = try? JSONSerialization.data(withJSONObject: element),
                   let a = try? JSONDecoder().decode(Automation.self, from: record) {
                    good.append(a)
                }
            }
            return good.isEmpty ? nil : AutomationStore(automations: good)
        }
    }

    public static func save(_ store: AutomationStore, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - OpenClaw compatibility

/// OpenClaw's `jobs.json`. Decoded liberally: any field this build doesn't
/// know is skipped rather than fatal.
public struct OpenClawJobsFile: Codable {
    public var version: Int?
    public var jobs: [OpenClawJob]?
}

public struct OpenClawJob: Codable {
    public var id: String?
    public var name: String?
    public var enabled: Bool?
    public var createdAtMs: Double?
    public var schedule: OpenClawSchedule?
    public var payload: OpenClawPayload?
    public var timeoutSeconds: Int?
}

public struct OpenClawSchedule: Codable {
    public var kind: String?
    public var expr: String?
    public var tz: String?
    public var everyMs: Int?
    public var anchorMs: Double?
    public var at: String?
}

public struct OpenClawPayload: Codable {
    public var kind: String?
    public var message: String?
    public var timeoutSeconds: Int?
}

public enum OpenClawCompat {
    /// Read an OpenClaw `jobs.json` and map every usable job to an Automation.
    /// Jobs that aren't a scheduled prompt (system events, unknown payloads)
    /// or whose schedule can't be parsed are skipped.
    public static func importJobs(from url: URL) -> [Automation] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(OpenClawJobsFile.self, from: data) else { return [] }
        return (file.jobs ?? []).compactMap(jobToAutomation)
    }

    public static func jobToAutomation(_ job: OpenClawJob) -> Automation? {
        guard let name = job.name, !name.isEmpty else { return nil }
        guard let payload = job.payload, payload.kind == "agentTurn",
              let message = payload.message, !message.isEmpty else { return nil }
        guard let raw = job.schedule, let kind = raw.kind else { return nil }
        let schedule: AutomationSchedule
        switch kind {
        case "cron":
            guard let expr = raw.expr, CronParser.fields(expr) != nil else { return nil }
            schedule = .cron(expr: expr, timeZone: raw.tz ?? TimeZone.current.identifier)
        case "every":
            guard let ms = raw.everyMs, ms > 0 else { return nil }
            let anchor = raw.anchorMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            schedule = .interval(seconds: max(1, ms / 1000), anchor: anchor)
        case "at":
            guard let at = raw.at else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = iso.date(from: at) ?? ISO8601DateFormatter().date(from: at) else { return nil }
            schedule = .once(at: date)
        default:
            return nil
        }
        var automation = Automation(id: job.id ?? UUID().uuidString, name: name, prompt: message,
                                    schedule: schedule, enabled: job.enabled ?? true,
                                    createdAt: job.createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now)
        automation.timeoutSeconds = payload.timeoutSeconds ?? job.timeoutSeconds
        return automation
    }

    /// Serialize automations into OpenClaw's `jobs.json` shape, so a library
    /// curated here can drive OpenClaw too.
    public static func exportJSON(_ automations: [Automation]) -> Data {
        struct Job: Codable {
            var id: String
            var agentId: String
            var sessionKey: String
            var name: String
            var enabled: Bool
            var createdAtMs: Double
            var schedule: [String: JSONValue]
            var sessionTarget: String
            var wakeMode: String
            var payload: [String: JSONValue]
            var delivery: [String: JSONValue]
            var state: [String: JSONValue]
        }
        struct File: Codable { var version: Int; var jobs: [Job] }
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        func job(_ a: Automation) -> Job {
            var schedule: [String: JSONValue] = [:]
            var payload: [String: JSONValue] = [:]
            payload["kind"] = .string("agentTurn")
            payload["message"] = .string(a.prompt)
            if let t = a.timeoutSeconds { payload["timeoutSeconds"] = .number(Double(t)) }
            switch a.schedule {
            case .cron(let expr, let tz):
                schedule["kind"] = .string("cron"); schedule["expr"] = .string(expr); schedule["tz"] = .string(tz)
            case .interval(let seconds, let anchor):
                schedule["kind"] = .string("every")
                schedule["everyMs"] = .number(Double(seconds * 1000))
                if let anchor { schedule["anchorMs"] = .number(anchor.timeIntervalSince1970 * 1000) }
            case .once(let at):
                schedule["kind"] = .string("at")
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                schedule["at"] = .string(f.string(from: at))
            }
            return Job(id: a.id, agentId: "main", sessionKey: "agent:main:main", name: a.name,
                       enabled: a.enabled, createdAtMs: a.createdAt.timeIntervalSince1970 * 1000,
                       schedule: schedule, sessionTarget: "isolated", wakeMode: "now",
                       payload: payload, delivery: ["mode": .string("none")], state: [:])
        }
        return (try? encoder.encode(File(version: 1, jobs: automations.map(job)))) ?? Data("{\"version\":1,\"jobs\":[]}".utf8)
    }
}

// MARK: - The scheduler's math

/// Pure next-run logic the app's timer polls. No timers here — the app layer
/// owns the tick so the whole engine stays testable.
public final class AutomationScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var store = AutomationStore()
    /// Automation id → its next fire time, cached so `dueAutomations` is cheap
    /// to poll every few seconds. Invalidated on any store change.
    private var nextRunCache: [String: Date] = [:]

    public init() {}

    public func replaceStore(_ newStore: AutomationStore) {
        lock.lock(); defer { lock.unlock() }
        store = newStore
        nextRunCache.removeAll()
    }

    public func currentStore() -> AutomationStore {
        lock.lock(); defer { lock.unlock() }
        return store
    }

    public func recordRun(id: String, at: Date = .now, status: String,
                          duration: TimeInterval?, sessionID: String?, detail: String?) {
        lock.lock()
        store.recordRun(id: id, at: at, status: status, duration: duration, sessionID: sessionID, detail: detail)
        nextRunCache.removeValue(forKey: id)
        lock.unlock()
    }

    public func nextRun(of automation: Automation, after date: Date) -> Date? {
        // Reference point: the later of the last run and creation, so a run
        // missed while the Mac slept doesn't stampede — the next occurrence is
        // computed from when it last *ran*, not from the cron's abstract grid.
        let reference = max(automation.lastRunAt ?? .distantPast, automation.createdAt)
        let from = max(date, reference)
        return AutomationNext.next(automation.schedule, after: from)
    }

    /// Enabled automations due at `now`.
    public func dueAutomations(now: Date) -> [Automation] {
        lock.lock(); defer { lock.unlock() }
        var due: [Automation] = []
        for a in store.automations where a.enabled {
            let next: Date
            if let cached = nextRunCache[a.id] {
                next = cached
            } else {
                guard let computed = nextRun(of: a, after: now) else {
                    nextRunCache[a.id] = .distantFuture
                    continue
                }
                nextRunCache[a.id] = computed
                next = computed
            }
            if next <= now { due.append(a) }
        }
        return due
    }

    /// Every occurrence of every enabled automation within `horizon` of `now`,
    /// sorted — the calendar's data.
    public func upcoming(now: Date, horizon: TimeInterval = 35 * 86400,
                         perAutomation: Int = 20, total: Int = 400) -> [(date: Date, automation: Automation)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(Date, Automation)] = []
        for a in store.automations where a.enabled {
            var cursor = max(now, max(a.lastRunAt ?? .distantPast, a.createdAt))
            var emitted = 0
            while emitted < perAutomation, out.count < total {
                guard let next = AutomationNext.next(a.schedule, after: cursor), next <= now.addingTimeInterval(horizon)
                else { break }
                out.append((next, a))
                cursor = next
                emitted += 1
                // `.once` fires exactly once.
                if case .once = a.schedule { break }
            }
        }
        return out.sorted { $0.0 < $1.0 }.map { (date: $0.0, automation: $0.1) }
    }
}
