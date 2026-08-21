import Foundation

// MARK: - Tool context / results

/// What a tool may touch while executing. Value-type, Sendable, no closures:
/// tools report side effects via `ToolResult` instead of callbacks.
public struct ToolContext: Sendable {
    public let workspace: URL
    public let policy: PermissionPolicy
    /// The live model client, so the `agent` tool can spawn a subagent.
    public let client: any LLMClient
    /// The registry, so the subagent gets the same capabilities.
    public let registry: ToolRegistry
    /// 0 = top-level session. Bounded to keep recursion sane.
    public let depth: Int
    /// Model id subagents should use (same as the parent session).
    public let model: String
    /// Asks the user for permission; subagents inherit the parent's hook.
    public let requestPermission: @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool

    public init(workspace: URL, policy: PermissionPolicy,
                client: any LLMClient, registry: ToolRegistry, depth: Int = 0,
                model: String = "",
                requestPermission: @escaping @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool = { _, _, _ in true }) {
        self.workspace = workspace
        self.policy = policy
        self.client = client
        self.registry = registry
        self.depth = depth
        self.model = model
        self.requestPermission = requestPermission
    }
}

/// A side effect the UI can observe (editor auto-reload, "produced files" chips).
public struct FileChange: Hashable, Sendable {
    public enum Kind: String, Sendable { case created, modified, deleted }
    public let url: URL
    public let kind: Kind

    public init(_ url: URL, _ kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// One structured todo, as the `todo_write` tool manages them.
public struct TodoItem: Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, inProgress = "in_progress", completed
    }
    public let id: String
    public var content: String
    public var status: Status

    public init(id: String, content: String, status: Status = .pending) {
        self.id = id
        self.content = content
        self.status = status
    }
}

/// The outcome of executing one tool call.
public struct ToolResult: Sendable {
    public let output: String
    public var files: [FileChange]
    public var todos: [TodoItem]?   // nil = this call did not manage todos

    public init(output: String, files: [FileChange] = [], todos: [TodoItem]? = nil) {
        self.output = output
        self.files = files
        self.todos = todos
    }
}

// MARK: - Executor protocol

/// A concrete tool implementation. Stateless value types keep Swift 6 happy.
public protocol ToolExecutor: Sendable {
    /// Stable name — matches the Qwen Code tool names.
    static var name: String { get }
    /// The OpenAI-shape tool spec sent to the model.
    static var spec: ToolSpec { get }
    /// Instance-level identity. Built-ins inherit it from the statics; tools
    /// whose name is data rather than a type (plugins) override it.
    var name: String { get }
    var spec: ToolSpec { get }
    func execute(args: JSONString, in context: ToolContext) async -> ToolResult
}

extension ToolExecutor {
    public var name: String { Self.name }
    public var spec: ToolSpec { Self.spec }
}

extension ToolExecutor {
    /// Decode arguments into a `[String: String]`-ish bag.
    /// Concrete-type access only; use `JSONArgs` at dynamic call sites.
    internal static func string(_ json: JSONString, _ key: String) -> String? {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict[key] as? String
    }
    internal static func int(_ json: JSONString, _ key: String, default def: Int) -> Int {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        if let n = dict[key] as? Int { return n }
        if let d = dict[key] as? Double { return Int(d) }
        return def
    }
    internal static func bool(_ json: JSONString, _ key: String, default def: Bool) -> Bool {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        return (dict[key] as? Bool) ?? def
    }
    internal static func dict(_ json: JSONString) -> [String: Any] {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return (obj as? [String: Any]) ?? [:]
    }
}

/// Argument-reader namespace. Callers holding an `any ToolExecutor` (or a
/// protocol metatype) can't reach the `ToolExecutor` extension's statics,
/// so these equivalents live on a concrete enum.
public enum JSONArgs {
    public static func string(_ json: JSONString, _ key: String) -> String? {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict[key] as? String
    }
    public static func int(_ json: JSONString, _ key: String, default def: Int) -> Int {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        if let n = dict[key] as? Int { return n }
        if let d = dict[key] as? Double { return Int(d) }
        return def
    }
    public static func bool(_ json: JSONString, _ key: String, default def: Bool) -> Bool {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        return (dict[key] as? Bool) ?? def
    }
    public static func dictionary(_ json: JSONString) -> [String: Any] {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return (obj as? [String: Any]) ?? [:]
    }
}

// MARK: - Registry

public struct ToolRegistry: Sendable {
    private let tools: [any ToolExecutor]

    public init(tools: [any ToolExecutor]) {
        self.tools = tools
    }

    public var specs: [ToolSpec] { tools.map(\.spec) }

    public var names: [String] { tools.map(\.name) }

    public func tool(named name: String) -> (any ToolExecutor)? {
        tools.first { $0.name == name }
    }

    /// A copy of this registry with extra tools appended (plugin contributions).
    public func adding(_ extra: [any ToolExecutor]) -> ToolRegistry {
        ToolRegistry(tools: tools + extra)
    }

    public static func standard(depth: Int = 0) -> ToolRegistry {
        // `agent` is only offered at the top level: subagents don't spawn
        // subagents (keeps the permission surface and cost predictable).
        var tools: [any ToolExecutor] = [
            ReadFileTool(), WriteFileTool(), EditTool(), ListDirectoryTool(),
            ReadManyFilesTool(), GlobTool(), GrepTool(),
            RunShellCommandTool(), WebFetchTool(), TodoWriteTool(), ExitPlanModeTool(),
        ]
        if depth == 0 { tools.append(AgentTool()) }
        return ToolRegistry(tools: tools)
    }
}