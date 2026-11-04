import Foundation

// MARK: - Harness memory (lives with the app, never in the code being edited)
//
// The harness remembers things across chats and projects: facts about the
// user, the people they work with, how they like things done, and the key
// details a long conversation produced. This memory belongs to the *installed
// harness* — `~/Library/Application Support/DSHMac/memory/` — deliberately NOT
// inside any project folder, so nothing about the user leaks into a repo and
// so it follows the app across every project it opens.
//
// Two layers:
//   MEMORY.md        durable facts, edited rarely, injected into every turn
//   memory/YYYY-MM-DD.md   a daily log the harness writes as it works
//
// The model contributes with the `save_memory` tool; compaction contributes
// by folding each summary's "Key facts" section in (see `Compaction`).

public struct HarnessMemory: Sendable {
    /// The app-support directory memory lives under (`…/DSHMac`).
    public let appSupport: URL

    public init(appSupport: URL) {
        self.appSupport = appSupport
    }

    public static var standard: HarnessMemory {
        HarnessMemory(appSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("DSHMac", isDirectory: true))
    }

    public var memoryFile: URL { appSupport.appendingPathComponent("MEMORY.md") }
    public var memoryDirectory: URL { appSupport.appendingPathComponent("memory", isDirectory: true) }

    public static func dayStamp(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Today's daily log, created if missing.
    public func dailyFile(_ date: Date = .now) -> URL {
        let dir = memoryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Self.dayStamp(date)).md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "# \(Self.dayStamp(date))\n\n- \n".write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Where today's log would live — reading this does not create it.
    public func dailyPath(_ date: Date = .now) -> URL {
        memoryDirectory.appendingPathComponent("\(Self.dayStamp(date)).md")
    }

    /// Ensure both files exist (scaffolded like a project's `Set Up Memory`).
    @discardableResult
    public func setUp() throws -> [URL] {
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        var created: [URL] = []
        if !FileManager.default.fileExists(atPath: memoryFile.path) {
            try """
            # Harness memory

            What the harness knows that outlives any one chat: the user, their projects and
            people, how they like things done. Injected into every session, so keep it short —
            one line per fact, newest insight at the bottom.

            -
            """.write(to: memoryFile, atomically: true, encoding: .utf8)
            created.append(memoryFile)
        }
        created.append(dailyFile())
        return created
    }

    // MARK: Reading

    /// The durable memory file's text (empty when it doesn't exist yet).
    public func durable() -> String {
        (try? String(contentsOf: memoryFile, encoding: .utf8)) ?? ""
    }

    /// Today's log (empty when missing — reading never creates the file).
    public func daily(_ date: Date = .now) -> String {
        (try? String(contentsOf: dailyPath(date), encoding: .utf8)) ?? ""
    }

    /// The prompt block: durable memory + today's log. Kept short — this rides
    /// on every request, so it is clipped well before it could crowd a window.
    public func promptBlock(date: Date = .now, cap: Int = 6_000) -> String {
        var parts: [String] = []
        let durable = self.durable().trimmingCharacters(in: .whitespacesAndNewlines)
        if !durable.isEmpty {
            parts.append("--- Harness memory (yours — persistent across chats and projects) ---\n\(durable)")
        }
        let daily = self.daily(date).trimmingCharacters(in: .whitespacesAndNewlines)
        if !daily.isEmpty {
            parts.append("--- Today's harness memory log ---\n\(daily)")
        }
        guard !parts.isEmpty else { return "" }
        var text = parts.joined(separator: "\n\n")
        if text.count > cap { text = String(text.suffix(cap)) }
        return text
    }

    // MARK: Writing

    /// Append a fact. `durable: true` writes into `MEMORY.md` (facts that
    /// should outlive the day); otherwise the daily log. Returns the file written.
    @discardableResult
    public func append(_ text: String, durable: Bool, at date: Date = .now) -> URL {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return memoryFile }
        let target = durable ? memoryFile : dailyFile(date)
        var body = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let entry = "- [\(Self.dayStamp(date))] \(clean.replacingOccurrences(of: "\n", with: " "))"
        if body.isEmpty {
            body = durable ? "# Harness memory\n\n\(entry)\n" : "# \(Self.dayStamp(date))\n\n\(entry)\n"
        } else {
            // Keep the scaffold's leading block intact; append at the end.
            if !body.hasSuffix("\n") { body += "\n" }
            body += entry + "\n"
        }
        try? body.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// Fold a compaction summary's extracted key facts in. Written to the
    /// daily log (not durable MEMORY.md) — the summarizer decides what is
    /// merely today's state vs. what earns a permanent line.
    @discardableResult
    public func recordKeyFacts(_ facts: [String], at date: Date = .now) -> URL {
        guard !facts.isEmpty else { return dailyFile(date) }
        let body = "Key facts from compaction: " + facts.joined(separator: " · ")
        return append(body, durable: false, at: date)
    }
}

// MARK: - The model's memory tools

/// `save_memory`: the model writes a fact it thinks it will need later — about
/// the user, a person, a project, a decision. Goes to the *harness* memory
/// (app support), never into the code folder.
public struct SaveMemoryTool: ToolExecutor {
    public static let name = "save_memory"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Save a fact you will need later to the harness's persistent memory — about the user, \
        a person they work with, a project, a preference, or a decision. Saved across all \
        chats and projects (never inside the code folder). Use for things worth remembering \
        beyond this conversation: not transient state. durable: true for lasting facts \
        (preferences, who people are), false for today's working state.
        """,
        parameters: """
        {"type":"object","properties":{
            "content":{"type":"string","description":"The fact, one line, specific."},
            "durable":{"type":"boolean","description":"true = lasting fact (default); false = today's log.","default":true}
        },"required":["content"]}
        """)

    public let memory: HarnessMemory

    public init(memory: HarnessMemory) { self.memory = memory }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let content = Self.string(args, "content") ?? ""
        let durable = Self.bool(args, "durable", default: true)
        guard !content.isEmpty else { return ToolResult(output: "Error: content is required.") }
        memory.append(content, durable: durable)
        return ToolResult(output: durable ? "Saved to harness memory (durable)." : "Saved to today's harness memory log.")
    }
}

/// `read_memory`: what the harness already knows, so the model doesn't ask or
/// re-derive it. The prompt block already carries it; this re-reads on demand.
public struct ReadMemoryTool: ToolExecutor {
    public static let name = "read_memory"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Read the harness's persistent memory: durable facts (MEMORY.md) and today's log. \
        The prompt already includes this; use this tool to re-check without waiting \
        for a fresh prompt, or to see more history than the prompt carries.
        """,
        parameters: """
        {"type":"object","properties":{
            "all":{"type":"boolean","description":"true = every daily log too (bounded); false = durable + today.","default":false}
        },"required":[]}
        """)

    public let memory: HarnessMemory

    public init(memory: HarnessMemory) { self.memory = memory }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        var parts = ["=== Harness memory (durable) ===", memory.durable()]
        if Self.bool(args, "all", default: false) {
            let files = (try? FileManager.default.contentsOfDirectory(at: memory.memoryDirectory,
                                                                     includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .prefix(14) ?? []
            for file in files {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                parts.append("=== \(file.lastPathComponent) ===\n\(String(text.suffix(2_000)))")
            }
        } else {
            parts.append("=== Today ===\n\(memory.daily())")
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(output: joined.isEmpty ? "Harness memory is empty." : String(joined.prefix(16_000)))
    }
}
