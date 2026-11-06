import Foundation

// MARK: - The harness's self-tools
//
// The model can look at — and manage — the harness itself: the credential
// vault, the automations, its own chat histories, and the memory. These are
// the same stores the UI drives, so anything done here shows up in the app
// (and the other way round). The vault tools are the exception in one
// direction: values the user hands over in chat land in the Keychain and are
// then scrubbed from every tool result from then on.
//
// Note on placeholders: the handle that pulls a value into a tool call is
// spelled with doubled braces around "vault:" — the strings below are built by
// concatenation so this source file never contains a live one (the harness
// substitutes those in tool arguments).

/// The placeholder handle, assembled so this file holds no live one.
public enum VaultPlaceholderText {
    public static let open = "{" + "{vault:"
    public static let close = "}}"
    /// The handle for `name`, as the agent writes it ("{{vault:NAME}}").
    public static func handle(_ name: String) -> String { open + name + close }
    /// The generic form used in docs ("{{vault:NAME}}").
    public static let generic = open + "NAME" + close
}

// MARK: Vault CRUD

/// `vault_add`: store a credential. The usual flow is the user pasting a value
/// (or pointing at a file to import); from then on the agent only ever writes
/// the placeholder handle and never sees the value again.
public struct VaultAddTool: ToolExecutor {
    public static let name = "vault_add"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Add a credential to the user's vault (Keychain-backed): an API key, token or password. \
        After this the value is substituted only where the placeholder handle (doubled braces \
        around vault: and the name) is written, and scrubbed from results. Use when the user \
        gives you a secret to keep (paste, file to import, migration) — never ask for a secret \
        that is already in the vault.
        """,
        parameters: """
        {"type":"object","properties":{
            "name":{"type":"string","description":"The handle for the placeholder: letters, digits, _ - or . (e.g. OPENAI_API_KEY)."},
            "value":{"type":"string","description":"The secret itself."},
            "kind":{"type":"string","enum":["apiKey","token","password","other"]},
            "description":{"type":"string","description":"What it is / where it's used."},
            "tags":{"type":"array","items":{"type":"string"}},
            "username":{"type":"string","description":"Account or login it belongs to, if any."},
            "url":{"type":"string","description":"Where it's used, e.g. https://api.openai.com."},
            "access":{"type":"string","enum":["allowed","ask","never"],"description":"May the agent use it freely (default), ask first, or never."}
        },"required":["name","value"]}
        """
    )

    public let vault: CredentialVault
    /// Called after a change so the UI and the next turn's prompt refresh.
    public let onChange: @Sendable () -> Void

    public init(vault: CredentialVault, onChange: @escaping @Sendable () -> Void = {}) {
        self.vault = vault
        self.onChange = onChange
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let name = Self.string(args, "name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(output: "Error: name is required (e.g. OPENAI_API_KEY).")
        }
        guard let value = Self.string(args, "value"), !value.isEmpty else {
            return ToolResult(output: "Error: value is required.")
        }
        let kind = Self.string(args, "kind").flatMap(VaultEntry.Kind.init(rawValue:)) ?? .apiKey
        let access = Self.string(args, "access").flatMap(VaultEntry.AgentAccess.init(rawValue:)) ?? .allowed
        let tags = Self.array(args, "tags").compactMap { $0 as? String }
        do {
            let entry = try vault.add(name: name, value: value, kind: kind,
                                      description: Self.string(args, "description") ?? "",
                                      tags: tags,
                                      username: Self.string(args, "username"),
                                      url: Self.string(args, "url"),
                                      access: access)
            onChange()
            let handle = VaultPlaceholderText.handle(entry.name)
            return ToolResult(output: "Stored \(handle) (\(entry.kind.label)\(access == .ask ? ", asks the user first" : "")). Refer to it as \(handle) — the value is hidden from you and scrubbed from results.")
        } catch {
            return ToolResult(output: "Error: \(error.localizedDescription)")
        }
    }
}

/// `vault_update`: change a credential's details, and optionally rotate its
/// value. Found by name.
public struct VaultUpdateTool: ToolExecutor {
    public static let name = "vault_update"
    public static let spec = ToolSpec(
        name: name,
        description: "Update a vault credential's description, tags, username, url, access level or value. Only what you pass changes.",
        parameters: """
        {"type":"object","properties":{
            "name":{"type":"string","description":"Which credential (its placeholder handle)."},
            "value":{"type":"string","description":"A new secret value (rotation). Optional."},
            "description":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}},
            "username":{"type":"string"},"url":{"type":"string"},
            "access":{"type":"string","enum":["allowed","ask","never"]}
        },"required":["name"]}
        """
    )

    public let vault: CredentialVault
    public let onChange: @Sendable () -> Void

    public init(vault: CredentialVault, onChange: @escaping @Sendable () -> Void = {}) {
        self.vault = vault
        self.onChange = onChange
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let name = Self.string(args, "name"), let entry = vault.entry(named: name) else {
            return ToolResult(output: "Error: no credential with that name (vault_search lists them).")
        }
        var updated = entry
        if let description = Self.string(args, "description") { updated.description = description }
        if Self.dict(args)["tags"] != nil { updated.tags = Self.array(args, "tags").compactMap { $0 as? String } }
        if let username = Self.string(args, "username") { updated.username = username }
        if let url = Self.string(args, "url") { updated.url = url }
        if let access = Self.string(args, "access").flatMap(VaultEntry.AgentAccess.init(rawValue:)) { updated.access = access }
        do {
            try vault.update(updated, value: Self.string(args, "value"))
            onChange()
            return ToolResult(output: "Updated \(entry.name).")
        } catch {
            return ToolResult(output: "Error: \(error.localizedDescription)")
        }
    }
}

/// `vault_delete`: remove a credential, by name. Only when the user asks.
public struct VaultDeleteTool: ToolExecutor {
    public static let name = "vault_delete"
    public static let spec = ToolSpec(
        name: name,
        description: "Delete a credential from the vault, by name. Only when the user asks — this cannot be undone.",
        parameters: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
    )

    public let vault: CredentialVault
    public let onChange: @Sendable () -> Void

    public init(vault: CredentialVault, onChange: @escaping @Sendable () -> Void = {}) {
        self.vault = vault
        self.onChange = onChange
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let name = Self.string(args, "name"), let entry = vault.entry(named: name) else {
            return ToolResult(output: "Error: no credential with that name.")
        }
        do {
            try vault.delete(id: entry.id)
            onChange()
            return ToolResult(output: "Deleted \(name).")
        } catch {
            return ToolResult(output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: Automations

/// `automation_run`: fire a scheduled automation right now, by id or name —
/// the same as pressing Run in the Automations calendar.
public struct AutomationRunTool: ToolExecutor {
    public static let name = "automation_run"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Run a scheduled automation now (it still runs in its own unattended chat, as usual). \
        Pass id or name from list_scheduled_tasks. Only when the user asks.
        """,
        parameters: """
        {"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"required":[]}
        """
    )

    /// Returns false when nothing has that id/name.
    public let run: @Sendable (String, String) async -> Bool

    public init(run: @escaping @Sendable (String, String) async -> Bool) { self.run = run }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let id = Self.string(args, "id") ?? ""
        let name = Self.string(args, "name") ?? ""
        guard !id.isEmpty || !name.isEmpty else {
            return ToolResult(output: "Error: pass id or name (list_scheduled_tasks shows both).")
        }
        guard await run(id, name) else {
            return ToolResult(output: "Error: no automation has that id or name.")
        }
        return ToolResult(output: "Running — it works in its own chat; its history lands in Automations.")
    }
}

// MARK: Chats

/// One chat transcript, decoded tolerantly from a conversation file. Kept
/// local to the search tool so `ConversationLog`'s shapes stay its own.
private struct TranscriptFile: Codable {
    var session: SessionMeta?
    var items: [Item]?
    struct SessionMeta: Codable { var id: String?; var title: String?; var kind: String? }
    struct Item: Codable {
        var kind: String?
        var text: String?
        var output: String?
        var at: Date?
    }
}

/// `chat_search`: full-text search across every chat's transcript — what the
/// user said, what the model answered, what tools printed. The way to answer
/// "when did we talk about X?" without asking.
public struct SearchChatsTool: ToolExecutor {
    public static let name = "chat_search"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Search all chat histories (every mode's transcripts on disk) for words — finds the chats \
        where something was discussed, with matching snippets. Use to recall a decision, a path, \
        a name from another conversation.
        """,
        parameters: """
        {"type":"object","properties":{
            "query":{"type":"string","description":"Words to match; every word must appear."},
            "limit":{"type":"integer","description":"Max matches (default 12)."}
        },"required":["query"]}
        """
    )

    /// The conversations folder (`AppPaths.conversations`). Injectable for tests.
    public let directory: URL
    public let limit: Int

    public init(directory: URL = AppPaths.conversations, limit: Int = 12) {
        self.directory = directory
        self.limit = limit
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let query = (Self.string(args, "query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ToolResult(output: "Error: query is required.") }
        let words = query.lowercased().split(separator: " ").map(String.init)
        let cap = max(1, Self.int(args, "limit", default: limit))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        struct Hit { let chatID: String; let title: String; let kind: String; let at: Date?; let snippet: String }
        var hits: [Hit] = []
        for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let transcript = try? JSONDecoder().decode(TranscriptFile.self, from: data) else { continue }
            let chatID = transcript.session?.id ?? file.deletingPathExtension().lastPathComponent
            let title = transcript.session?.title ?? chatID
            for item in transcript.items ?? [] {
                let haystacks = [item.text, item.output].compactMap { $0 }
                for text in haystacks {
                    let lower = text.lowercased()
                    guard words.allSatisfy({ lower.contains($0) }) else { continue }
                    // A line that carries every word, else a window around the first.
                    let snippet = Self.snippet(from: text, words: words)
                    hits.append(Hit(chatID: chatID, title: title, kind: item.kind ?? "text",
                                    at: item.at, snippet: snippet))
                    break
                }
                if hits.count >= cap * 4 { break }
            }
            if hits.count >= cap * 4 { break }
        }
        guard !hits.isEmpty else {
            return ToolResult(output: "No chat mentions “\(query)” (\(files.count) chats searched).")
        }
        var lines: [String] = []
        var seen = Set<String>()
        for hit in hits {
            let key = hit.chatID + hit.snippet
            guard seen.insert(key).inserted else { continue }
            let when = hit.at.map { " · " + Self.day($0) } ?? ""
            lines.append("\(hit.title) (\(hit.chatID.prefix(8))) · [\(hit.kind)]\(when)\n  \(hit.snippet)")
            if lines.count >= cap { break }
        }
        lines.append("Open a chat by its title in the sidebar; read_chat reads an adjacent conversation by id.")
        return ToolResult(output: lines.joined(separator: "\n"))
    }

    static func snippet(from text: String, words: [String]) -> String {
        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            if words.allSatisfy({ lower.contains($0) }) {
                return String(line.trimmingCharacters(in: .whitespaces).prefix(240))
            }
        }
        guard let range = text.lowercased().range(of: words[0]) else {
            return String(text.prefix(240))
        }
        let start = text.index(range.lowerBound, offsetBy: -min(60, text.distance(from: text.startIndex, to: range.lowerBound)), limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(240))
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: Introspection

/// `harness_info`: what the harness itself is — version, data folder, memory,
/// the vault, schedules, prompt history — so the model can answer "what do you
/// have?" and act on it without guessing paths.
public struct HarnessInfoTool: ToolExecutor {
    public static let name = "harness_info"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Introspect the harness itself: app version and data folder, harness memory file paths, \
        credential vault count, scheduled automations, prompt-history count, and the chat \
        transcripts folder. Use to see what the harness has before importing, migrating or reporting.
        """,
        parameters: #"{"type":"object","properties":{}}"#
    )

    public let memory: HarnessMemory
    public let vault: CredentialVault
    public let promptHistory: PromptHistoryStore
    public let scheduled: @Sendable () async -> [Automation]

    public init(memory: HarnessMemory, vault: CredentialVault, promptHistory: PromptHistoryStore,
                scheduled: @escaping @Sendable () async -> [Automation]) {
        self.memory = memory
        self.vault = vault
        self.promptHistory = promptHistory
        self.scheduled = scheduled
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let automations = await scheduled()
        let lines = [
            "App: \(AppIdentity.name) \(AppIdentity.version) (\(AppIdentity.bundleIdentifier))",
            "Data folder: \(AppPaths.support.path)",
            "Chat transcripts: \(AppPaths.conversations.path)",
            "Memory: durable \(memory.memoryFile.path); daily logs \(memory.memoryDirectory.path)/",
            "Vault: \(vault.all.count) credential\(vault.all.count == 1 ? "" : "s") — vault_search lists them; vault_add/_update/_delete manage them.",
            "Prompt history: \(promptHistory.count) record\(promptHistory.count == 1 ? "" : "s") (all modes).",
            "Automations: \(automations.isEmpty ? "none scheduled" : "\(automations.count) scheduled") —"
                + automations.prefix(10).map { " \($0.name) [\($0.schedule.label), \($0.enabled ? "on" : "off")]" }.joined(separator: ";"),
        ]
        return ToolResult(output: lines.joined(separator: "\n"))
    }
}

// MARK: Memory import

/// `import_memory`: pull memories from another install — OpenClaw's
/// `~/.openclaw/memory/`, a Vision backup's MEMORY.md + memory/, or the
/// archive folders on the drive — into *this* harness's general memory, where
/// every mode and every chat reads them.
public struct ImportMemoryTool: ToolExecutor {
    public static let name = "import_memory"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Import memories from another agent install into this harness's general memory (available \
        in every mode and chat). Point at a folder or file: a MEMORY.md, a memory/ directory of \
        daily logs, OpenClaw's ~/.openclaw/memory, or a Vision backup. Lines are deduplicated; \
        durable=true puts them in MEMORY.md (default), false into dated daily logs.
        """,
        parameters: """
        {"type":"object","properties":{
            "path":{"type":"string","description":"A file or folder to import from."},
            "durable":{"type":"boolean","description":"true = durable MEMORY.md (default); false = daily logs.","default":true}
        },"required":["path"]}
        """
    )

    public let memory: HarnessMemory

    public init(memory: HarnessMemory) { self.memory = memory }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard var path = Self.string(args, "path"), !path.isEmpty else {
            return ToolResult(output: "Error: path is required (a folder or a .md file).")
        }
        if path.hasPrefix("~") {
            path = NSString(string: path).expandingTildeInPath
        }
        let durable = Self.bool(args, "durable", default: true)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ToolResult(output: "Error: nothing exists at \(path).")
        }
        let result = memory.importMemories(from: url, durable: durable)
        if result.filesRead == 0 {
            return ToolResult(output: "Error: no readable .md files under \(path).")
        }
        return ToolResult(output: """
            Imported \(result.linesAdded) new line\(result.linesAdded == 1 ? "" : "s") from \(result.filesRead) \
            file\(result.filesRead == 1 ? "" : "s") (\(result.linesSkipped) already known) into \
            \(durable ? "durable MEMORY.md" : "the daily logs"). Written to \(result.target.path).
            """)
    }
}
