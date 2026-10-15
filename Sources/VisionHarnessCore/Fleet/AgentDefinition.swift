import Foundation

// MARK: - Agent types
//
// A subagent is a fresh engine working one task. Its *type* decides what it is told to be and which
// tools it may touch: an explorer reads and reports, a worker edits and builds. The built-in types cover
// the usual division of labour; more come from markdown files — the same shape Claude Code uses
// (frontmatter: name, description, tools, model; the body is the system prompt), so agent folders that
// already exist are read in place.

/// What a kind of subagent is and may do.
public struct AgentDefinition: Sendable, Hashable {
    /// The value of the agent tool's `agent_type`.
    public var name: String
    /// When to use it; shown to the model in the agent tool's description.
    public var description: String
    /// Instructions added to the standard subagent prompt.
    public var prompt: String
    /// The only tools it may use (DSH tool names). Nil = everything the parent has except the agent tools.
    public var tools: [String]?
    /// Tools it may not use even though `tools` would allow them (a file's `disallowedTools`).
    public var disallowedTools: [String]?
    /// Prefer the model server whose name contains this (e.g. "spark-2"); nil = whichever is free.
    public var server: String?
    /// Its own step budget; nil = the default.
    public var maxSteps: Int?
    public var readOnly: Bool
    /// "built-in", "user" or "project".
    public var origin: String
    /// The file it was read from.
    public var path: URL?

    public init(name: String = "", description: String = "", prompt: String = "",
                tools: [String]? = nil, disallowedTools: [String]? = nil, server: String? = nil,
                maxSteps: Int? = nil, readOnly: Bool = false, origin: String = "built-in", path: URL? = nil) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.tools = tools
        self.disallowedTools = disallowedTools
        self.server = server
        self.maxSteps = maxSteps
        self.readOnly = readOnly
        self.origin = origin
        self.path = path
    }

    /// It can only read: every tool it has is a read-only one. Judged from the tools, not from the name
    /// or a flag, so a project file that replaces "explore" with one that has a shell is not mistaken
    /// for the built-in.
    public var isReadOnly: Bool {
        guard let tools, !tools.isEmpty else { return false }
        return tools.allSatisfy { Self.readOnlyTools.contains($0) }
    }

    public static let general = "general"

    /// Tools that only read: nothing here changes a file or runs a command.
    public static let readOnlyTools: [String] =
        ["read_file", "read_many_files", "glob", "grep", "list_directory", "web_fetch", "memory_search"]

    public static let builtIn: [AgentDefinition] = [
        AgentDefinition(
            name: general,
            description: "A capable all-round worker with every tool. The default."),
        AgentDefinition(
            name: "explore",
            description: "Fast, read-only investigator: finds files, traces usages, answers \"where is X / how does Y work\" with file:line evidence. Never changes anything.",
            prompt: "You are a read-only investigator. Search widely before concluding: try several names, spellings and locations, and "
                + "read the code you find rather than guessing from file names. Report what you found as a short list of facts, each "
                + "with its evidence (`path:line`). Say plainly what you looked for and did not find. You cannot change files.",
            tools: readOnlyTools, maxSteps: 40, readOnly: true),
        AgentDefinition(
            name: "plan",
            description: "Read-only planner: studies the code and returns a concrete step-by-step plan (files to touch, order, risks). Changes nothing.",
            prompt: "You are a planner. Study the relevant code, then return a numbered plan another engineer could follow without "
                + "asking questions: which files change and how, in what order, what could go wrong, and how to check each step. "
                + "Prefer the smallest change that fully solves the task. You cannot change files.",
            tools: readOnlyTools, maxSteps: 40, readOnly: true),
        AgentDefinition(
            name: "review",
            description: "Reviews code or a diff for bugs, security problems and unclear code; reports findings by severity. Reads and runs read-only commands.",
            prompt: "You are a code reviewer. Read the code or diff you are pointed at (git diff / git log are fine; run nothing that "
                + "changes the tree). Report only real problems: a bug with the input that triggers it, a security hole, a broken "
                + "assumption. Rank them (high / medium / low), give `path:line` for each, and suggest the fix. If it is sound, say so.",
            tools: readOnlyTools + ["run_shell_command"], maxSteps: 40, readOnly: true),
        AgentDefinition(
            name: "worker",
            description: "Implements one well-specified change: edits files, runs builds and tests, reports what changed. Give it a complete task and the files involved.",
            prompt: "You are an implementer. Do exactly the task you were given: read before you edit, make focused changes, then build "
                + "and run the relevant tests and fix what you broke. Your report lists each file you changed and what changed in it, "
                + "the commands you ran with their results, and anything left undone.",
            maxSteps: 60),
    ]

    // MARK: Parsing

    /// Read one agent file. Nil when it has no name or nothing to say.
    public static func parse(_ text: String, fallbackName: String, origin: String, path: URL?) -> AgentDefinition? {
        let doc = SkillDocument.parse(droppingCommentsInsideBlocks(text))
        let name = slug(doc["name"] ?? fallbackName)
        guard !name.isEmpty else { return nil }
        let body = doc.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (doc["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty && description.isEmpty { return nil }
        let requested = doc.list("tools")
        var tools = resolveTools(requested)
        let toolsLine = hasTopLevelKey(text, "tools")
        // A list that names only tools DSH doesn't have (Task, NotebookRead, mcp__github__…), or is left blank,
        // must not mean "everything": that would hand a restricted agent the shell and every write. It gets the
        // tools that only read. (Only a file with no `tools` line at all takes them all.)
        // (The frontmatter reader can lose a key whose block it cannot make sense of; the line itself is proof
        // it was written.)
        if tools == nil, !requested.isEmpty || toolsLine || doc.fields["tools"] != nil || doc.lists["tools"] != nil {
            tools = readOnlyTools
        }
        let disallowed = resolveTools(doc.list("disallowedTools") + doc.list("disallowed_tools") + doc.list("disallowed-tools"))
        let readOnly = doc.bool("readonly") == true || doc.bool("read-only") == true
        if readOnly && tools == nil { tools = readOnlyTools }
        let stepsText = doc["max_steps"] ?? doc["maxSteps"] ?? doc["max-steps"]
        let steps = stepsText.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? min($0, 200) : nil }
        var server = (doc["server"] ?? doc["model"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude Code's model shortcuts ("sonnet", "inherit") name nothing a DSH server could match.
        if let named = server, ["inherit", "sonnet", "opus", "haiku", "fast", ""].contains(named) { server = nil }
        return AgentDefinition(name: name,
                               description: description.isEmpty ? String(body.prefix(140)) : description,
                               prompt: body, tools: tools, disallowedTools: disallowed, server: server,
                               maxSteps: steps, readOnly: readOnly, origin: origin, path: path)
    }

    /// Whether the frontmatter has a top-level line for `key`, read straight from the text.
    private static func hasTopLevelKey(_ text: String, _ key: String) -> Bool {
        var source = text
        while source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return false }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" || trimmed == "..." { return false }
            if let first = line.first, !first.isWhitespace, first != "#",
               line.range(of: key, options: [.caseInsensitive, .anchored]) != nil {
                let after = line.dropFirst(key.count).drop(while: { $0.isWhitespace })
                if after.hasPrefix(":") { return true }
            }
        }
        return false
    }

    /// The text with the comment lines that sit *inside* a frontmatter value taken out. A comment in the middle of
    /// a list (`  # - Bash`) is neither an item nor text; `SkillDocument` — which the skills use too — would let it
    /// spoil the whole list, and with it the agent's tool restriction. Comments inside a block scalar (`|` or `>`)
    /// are its text and stay.
    static func droppingCommentsInsideBlocks(_ text: String) -> String {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  let trimmed = $0.trimmingCharacters(in: .whitespaces)
                  return trimmed == "---" || trimmed == "..."
              }) else { return text }
        var kept: [String] = [lines[0]]
        var inBlockScalar = false
        for line in lines[1..<end] {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                let isComment = line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#")
                if isComment && !inBlockScalar { continue }
            } else if !line.isEmpty {
                inBlockScalar = false
                if !line.hasPrefix("#"), let colon = keyColon(in: line) {
                    let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    inBlockScalar = rest.hasPrefix("|") || rest.hasPrefix(">")
                }
            }
            kept.append(line)
        }
        kept.append(contentsOf: lines[end...])
        return kept.joined(separator: "\n")
    }

    /// The colon ending a top-level key (not prose containing a colon) — the same rule the frontmatter reader uses.
    private static func keyColon(in line: String) -> String.Index? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        if key.contains(" ") && !key.hasPrefix("\"") { return nil }
        return colon
    }

    /// Claude-style tool names (Read, Bash, WebFetch) → DSH's; unknown names are dropped. Nil when none of them mean
    /// anything here (the caller decides what that means — for an allow list, only the read tools).
    static func resolveTools(_ requested: [String]) -> [String]? {
        guard !requested.isEmpty else { return nil }
        var resolved: [String] = []
        for raw in requested {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased().replacingOccurrences(of: "-", with: "_")
            let mapped: String?
            switch key {
            case "read", "readfile", "read_file", "view": mapped = "read_file"
            case "read_many_files", "readmanyfiles": mapped = "read_many_files"
            case "grep", "search": mapped = "grep"
            case "glob", "find": mapped = "glob"
            case "ls", "list", "listdirectory", "list_directory": mapped = "list_directory"
            case "bash", "shell", "run_shell_command", "powershell": mapped = "run_shell_command"
            case "edit", "multiedit": mapped = "edit"
            case "write", "write_file", "writefile": mapped = "write_file"
            case "webfetch", "web_fetch", "websearch": mapped = "web_fetch"
            case "todowrite", "todo_write": mapped = "todo_write"
            case "memory_search", "memory_save", "memory_forget", "use_skill", "vault_search",
                 "process_start", "process_read", "process_write", "process_stop", "process_list":
                mapped = key
            default: mapped = nil
            }
            if let mapped, !resolved.contains(mapped) { resolved.append(mapped) }
        }
        return resolved.isEmpty ? nil : resolved
    }

    private static func slug(_ name: String) -> String {
        var text = ""
        for c in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if c.isLetter || c.isNumber {
                text.append(c)
            } else if (c == " " || c == "-" || c == "_"), let last = text.last, last != "-" {
                text.append("-")
            }
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// The agent types a chat can use: the built-in ones, then `.md` files from the user's and the project's agent
/// folders, later ones replacing earlier ones of the same name.
public struct AgentCatalog: Sendable, Equatable {
    public static let `default` = AgentCatalog(AgentDefinition.builtIn)

    public let all: [AgentDefinition]

    public init(_ all: [AgentDefinition]) {
        self.all = all
    }

    /// The type called `name` (case-insensitive); the general type for nil or empty; nil if unknown.
    public func find(_ name: String?) -> AgentDefinition? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = trimmed.isEmpty ? AgentDefinition.general : trimmed
        return all.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Whether the type called `name` can only read (an unknown name is a general agent, which can write).
    public func readOnlyType(_ name: String?) -> Bool {
        find(name)?.isReadOnly == true
    }

    /// "name: description" entries for the agent tool's description, so the model knows its choices.
    public func describe() -> String {
        all.prefix(10).map { "\($0.name): \(String($0.description.prefix(130)))" }.joined(separator: "; ")
    }

    // MARK: Loading

    /// Load built-ins, then every agent file in `userDirectories`, then in the project's `.claude/agents`, then
    /// the app's own (`.vision/agents`, with `.dsh/agents` from before the rename under it): project files win, and
    /// the app's own folder wins over Claude's. Unreadable files are skipped.
    public static func load(workspace: URL?, userDirectories: [URL]? = nil) -> AgentCatalog {
        var byName: [String: AgentDefinition] = [:]
        for built in AgentDefinition.builtIn { byName[built.name.lowercased()] = built }
        for directory in userDirectories ?? defaultUserDirectories() {
            merge(into: &byName, directory: directory, origin: "user")
        }
        if let workspace {
            merge(into: &byName, directory: workspace.appendingPathComponent(".claude/agents", isDirectory: true), origin: "project")
            for directory in AppPaths.projectFolders(workspace, "agents").reversed() {
                merge(into: &byName, directory: directory, origin: "project")
            }
        }
        let builtInOrder = AgentDefinition.builtIn.map(\.name)
        let ordered = byName.values.sorted { a, b in
            let ia = builtInOrder.firstIndex(of: a.name) ?? Int.max
            let ib = builtInOrder.firstIndex(of: b.name) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.lowercased() < b.name.lowercased()
        }
        return AgentCatalog(ordered)
    }

    /// Changes when an agent file is added, removed or edited in the folders `load` reads — cheap enough to ask
    /// before every turn, so a file written while the app is running is picked up.
    public static func stamp(workspace: URL?, userDirectories: [URL]? = nil) -> String {
        var folders = userDirectories ?? defaultUserDirectories()
        if let workspace {
            folders.append(workspace.appendingPathComponent(".claude/agents", isDirectory: true))
            folders += AppPaths.projectFolders(workspace, "agents")
        }
        var stamp: UInt64 = 17
        for folder in folders {
            for file in agentFiles(in: folder) {
                let real = file.resolvingSymlinksInPath()
                let values = try? real.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let ticks = UInt64(max(0, ((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 10_000_000).rounded()))
                let length = UInt64(max(0, values?.fileSize ?? 0))
                // Summed, not chained, so the order the disk lists files in doesn't matter.
                stamp = stamp &+ (fnv1a(file.path.lowercased()) ^ ticks ^ length)
            }
        }
        return String(stamp)
    }

    /// Where the user's own agent files live: the app's support folder, then Claude Code's `~/.claude/agents`.
    public static func defaultUserDirectories() -> [URL] {
        let places = SkillLocations.standard
        return [places.appSupport.appendingPathComponent("agents", isDirectory: true),
                places.home.appendingPathComponent(".claude/agents", isDirectory: true)]
    }

    /// The `*.md` files directly inside `directory`, in a stable order. Hidden files are skipped — a `._name.md` on a
    /// network or external volume is macOS metadata, not an agent.
    private static func agentFiles(in directory: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.path.lowercased() < $1.path.lowercased() }
    }

    private static func merge(into byName: inout [String: AgentDefinition], directory: URL, origin: String) {
        for file in agentFiles(in: directory) {
            // One unreadable file must not hide the rest.
            let real = file.resolvingSymlinksInPath()
            guard let size = (try? real.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 200_000,
                  let data = try? Data(contentsOf: real) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if let parsed = AgentDefinition.parse(text, fallbackName: file.deletingPathExtension().lastPathComponent,
                                                  origin: origin, path: file) {
                byName[parsed.name.lowercased()] = parsed
            }
        }
    }

    /// FNV-1a: a hash that is the same in every run (Swift's own `hashValue` is seeded per process).
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
