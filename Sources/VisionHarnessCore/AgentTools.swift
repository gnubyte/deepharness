import Foundation

// MARK: - Tools for the persistent agent

/// Saves a skill the agent wrote straight into the user's skills: active on
/// the next turn, no approval step. Agent mode only, and only while the
/// "agent saves skills itself" setting is on (otherwise it gets `propose_skill`).
public struct CreateSkillTool: ToolExecutor {
    public static let name = "create_skill"
    public static let spec = ToolSpec(
        name: name,
        description: "Save a reusable skill now. It's active from the next turn, in every chat. Use it after finishing a multi-step procedure you'd want to repeat, or when the user corrects how something should be done. Saving under an existing name replaces that skill, so use this to improve one. Tell the user in one line what you saved.",
        parameters: """
        {"type":"object","properties":{"name":{"type":"string","description":"lowercase-hyphen name, e.g. weekly-ticket-sweep"},"description":{"type":"string","description":"One or two sentences: when to use this skill, with trigger words"},"instructions":{"type":"string","description":"The skill body in Markdown: goal, numbered steps, exact commands, gotchas"}},"required":["name","description","instructions"]}
        """
    )

    public let locations: SkillLocations
    public let onSaved: @Sendable (String) -> Void

    public init(locations: SkillLocations = .standard, onSaved: @escaping @Sendable (String) -> Void = { _ in }) {
        self.locations = locations
        self.onSaved = onSaved
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let slug = SkillNaming.slug(Self.string(args, "name") ?? "")
        let description = (Self.string(args, "description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = (Self.string(args, "instructions") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return ToolResult(output: "Error: give the skill a lowercase-hyphen name.") }
        guard !description.isEmpty else { return ToolResult(output: "Error: the description must say when to use the skill.") }
        guard instructions.count >= 20 else { return ToolResult(output: "Error: the instructions are empty or too short to be useful.") }
        guard instructions.count <= 60_000 else { return ToolResult(output: "Error: the instructions are too long (max 60,000 characters).") }
        let text = "---\nname: \(slug)\ndescription: \(SkillDocument.scalar(description))\n---\n\n\(instructions)\n"
        do {
            let url = try SkillManager.create(text: text, scope: .user, projectRoot: nil, conflict: .replace, locations: locations)
            onSaved(slug)
            return ToolResult(output: "Saved skill “\(slug)” to \(url.path). It is active from the next turn.")
        } catch {
            return ToolResult(output: "Error: \(error.localizedDescription)")
        }
    }
}

/// Turns the arguments of `schedule_task` into a schedule.
public enum ScheduleRequest {
    public static func parse(at: String?, cron: String?, everyMinutes: Int?, now: Date = .now) -> Result<AutomationSchedule, ScheduleError> {
        let given = [at != nil, cron != nil, everyMinutes != nil].filter { $0 }.count
        guard given == 1 else { return .failure(.init("Give exactly one of `at`, `cron` or `every_minutes`.")) }
        if let at {
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = plain.date(from: at) ?? fractional.date(from: at) else {
                return .failure(.init("`at` must be ISO-8601 with an offset, like 2026-11-05T09:00:00-08:00."))
            }
            guard date > now else { return .failure(.init("That time has already passed.")) }
            return .success(.once(at: date))
        }
        if let cron {
            let expression = cron.trimmingCharacters(in: .whitespaces)
            guard expression.split(whereSeparator: \.isWhitespace).count == 5,
                  AutomationNext.next(.cron(expr: expression, timeZone: TimeZone.current.identifier), after: now) != nil else {
                return .failure(.init("`cron` must be a valid 5-field expression, like 30 8 * * 1-5."))
            }
            return .success(.cron(expr: expression, timeZone: TimeZone.current.identifier))
        }
        guard let everyMinutes, everyMinutes >= 1 else { return .failure(.init("`every_minutes` must be at least 1.")) }
        return .success(.interval(seconds: everyMinutes * 60, anchor: now))
    }

    public struct ScheduleError: Error, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
    }
}

/// Lets the agent put work on the user's calendar (the Automations mode).
public struct ScheduleTaskTool: ToolExecutor {
    public static let name = "schedule_task"
    public static let spec = ToolSpec(
        name: name,
        description: "Schedule a prompt to run unattended later in its own chat, when the user asks for a reminder or recurring or future work. It shows on the calendar in Automations. Don't schedule anything the user didn't ask for. Give exactly one of at, cron or every_minutes.",
        parameters: """
        {"type":"object","properties":{"name":{"type":"string","description":"Short name shown on the calendar"},"prompt":{"type":"string","description":"The full instructions the run gets; it has no memory of this chat, so include everything it needs"},"at":{"type":"string","description":"One run: ISO-8601 with offset, e.g. 2026-11-05T09:00:00-08:00"},"cron":{"type":"string","description":"Recurring: 5-field cron in the user's time zone, e.g. 30 8 * * 1-5"},"every_minutes":{"type":"integer","description":"Recurring: run every N minutes"}},"required":["name","prompt"]}
        """
    )

    public let add: @Sendable (Automation) async -> Void

    public init(add: @escaping @Sendable (Automation) async -> Void) { self.add = add }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let name = (Self.string(args, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (Self.string(args, "prompt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return ToolResult(output: "Error: name and prompt are required.") }
        let minutes = Self.string(args, "every_minutes").flatMap(Int.init)
            ?? { let n = Self.int(args, "every_minutes", default: -1); return n == -1 ? nil : n }()
        switch ScheduleRequest.parse(at: Self.string(args, "at"), cron: Self.string(args, "cron"), everyMinutes: minutes) {
        case .failure(let error):
            return ToolResult(output: "Error: \(error.message)")
        case .success(let schedule):
            let automation = Automation(name: name, prompt: prompt, schedule: schedule, projectPath: context.workspace.path)
            await add(automation)
            return ToolResult(output: "Scheduled “\(name)” (\(schedule.label)), id \(automation.id). The user can see and change it in Automations.")
        }
    }
}

public struct ListScheduledTasksTool: ToolExecutor {
    public static let name = "list_scheduled_tasks"
    public static let spec = ToolSpec(
        name: name,
        description: "List what's scheduled in Automations: id, name, schedule, whether it's on, and how the last run went.",
        parameters: #"{"type":"object","properties":{}}"#
    )

    public let list: @Sendable () async -> [Automation]

    public init(list: @escaping @Sendable () async -> [Automation]) { self.list = list }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let items = await list()
        guard !items.isEmpty else { return ToolResult(output: "Nothing is scheduled.") }
        return ToolResult(output: items.map { item in
            "\(item.id) · \(item.name) · \(item.schedule.label) · \(item.enabled ? "on" : "off")"
                + (item.lastStatus.map { " · last run: \($0)" } ?? "")
        }.joined(separator: "\n"))
    }
}

public struct CancelScheduledTaskTool: ToolExecutor {
    public static let name = "cancel_scheduled_task"
    public static let spec = ToolSpec(
        name: name,
        description: "Remove a scheduled task from Automations, by the id from list_scheduled_tasks. Only when the user asks.",
        parameters: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#
    )

    public let cancel: @Sendable (String) async -> Bool

    public init(cancel: @escaping @Sendable (String) async -> Bool) { self.cancel = cancel }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let id = Self.string(args, "id"), await cancel(id) else {
            return ToolResult(output: "Error: no scheduled task has that id.")
        }
        return ToolResult(output: "Removed.")
    }
}
