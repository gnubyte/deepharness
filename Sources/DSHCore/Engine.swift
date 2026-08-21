import Foundation

// MARK: - Engine events (observed by the UI)

public enum EngineEvent: Sendable {
    /// A chunk of assistant text arrived.
    case textDelta(String)
    /// The assistant's message for this turn is complete (text + any tool calls).
    case assistantMessage(id: String, text: String, calls: [ToolCall])
    /// A tool call is about to execute.
    case toolStarted(id: String, name: String, preview: String)
    /// A tool call finished. `summary` is a one-line headline; `output` is the
    /// full (already length-capped) result the UI reveals on demand.
    case toolFinished(id: String, name: String, ok: Bool, summary: String, output: String)
    /// Files a tool created, modified, or deleted — the editor reloads on these.
    case filesChanged([FileChange])
    /// The whole run finished cleanly.
    case finished(usage: LLMUsage?)
    /// The model asked for something the policy flagged; `id` pairs with toolFinished
    /// once the user's decision lands (approved: executes; denied: recorded as denial).
    case permissionQuestion(id: String, name: String, detail: String)
    /// A tool pushed a todo list for the UI.
    case todos([TodoItem])
    /// The run failed (network error, provider error, …).
    case failed(String)
}

/// Everything a run returns to its caller.
public struct RunResult: Sendable {
    /// Full message list, ready to feed back next run.
    public let messages: [LLMMessage]
    public let usage: LLMUsage?
    public let deniedCount: Int
    /// The assistant text of the final turn (empty if the run was cut off mid-tools).
    public let finalText: String

    public init(messages: [LLMMessage], usage: LLMUsage?, deniedCount: Int, finalText: String) {
        self.messages = messages
        self.usage = usage
        self.deniedCount = deniedCount
        self.finalText = finalText
    }
}

public struct EngineConfig: Sendable {
    public var maxIterations: Int
    public var toolTimeout: TimeInterval
    public var model: String
    public var temperature: Double?
    public var maxOutputTokens: Int?

    public init(maxIterations: Int = 30, toolTimeout: TimeInterval = 300,
                model: String, temperature: Double? = nil, maxOutputTokens: Int? = nil) {
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.model = model
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }
}

// MARK: - The engine

/// Agent engine: one `run` takes the current transcript and returns the
/// extended one, emitting events along the way. The transcript stays with the
/// caller, which keeps persistence trivial.
public struct Engine: Sendable {
    public let client: any LLMClient
    public let registry: ToolRegistry
    public let systemPrompt: String
    public let config: EngineConfig
    /// Workspace + policy for the run.
    public let workspace: URL
    public let policy: PermissionPolicy
    /// Ask the user whether a flagged tool call may proceed.
    /// Return `true` to approve, `false` to deny.
    public let permissionGate: @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool
    /// Where structured todos are pushed for UI rendering.
    public let onTodos: @Sendable ([TodoItem]) -> Void

    public init(client: any LLMClient,
                registry: ToolRegistry,
                systemPrompt: String,
                config: EngineConfig,
                workspace: URL,
                policy: PermissionPolicy,
                permissionGate: @escaping @Sendable (String, String, String) async -> Bool,
                onTodos: @escaping @Sendable ([TodoItem]) -> Void = { _ in }) {
        self.client = client
        self.registry = registry
        self.systemPrompt = systemPrompt
        self.config = config
        self.workspace = workspace
        self.policy = policy
        self.permissionGate = permissionGate
        self.onTodos = onTodos
    }

    /// Convenience for tests / subagents with auto-approval.
    public static func autoApproving(client: any LLMClient,
                                     registry: ToolRegistry,
                                     systemPrompt: String,
                                     config: EngineConfig,
                                     workspace: URL,
                                     policy: PermissionPolicy) -> Engine {
        Engine(client: client, registry: registry, systemPrompt: systemPrompt,
               config: config, workspace: workspace, policy: policy,
               permissionGate: { _, _, _ in true })
    }

    // MARK: - Run

    /// Drive one user turn to completion, executing tool calls along the way.
    /// Emits events to `sink` as they happen.
    @discardableResult
    public func run(messages input: [LLMMessage],
                    userText: String,
                    sink: @escaping @Sendable (EngineEvent) -> Void) async throws -> RunResult {
        var messages = input
        if !userText.isEmpty {
            messages.append(.user(userText))
        }
        var usage: LLMUsage? = nil
        var denied = 0
        var finalText = ""

        for iteration in 0..<config.maxIterations {
            if Task.isCancelled { throw CancellationError() }

            let request = LLMRequest(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: registry.specs,
                model: config.model,
                temperature: config.temperature,
                maxTokens: config.maxOutputTokens
            )

            // -- Model turn --
            var text = ""
            var calls: [ToolCall] = []
            var turnUsage: LLMUsage? = nil
            do {
                for try await event in client.stream(request) {
                    if Task.isCancelled { throw CancellationError() }
                    switch event {
                    case .text(let d):
                        text += d
                        sink(.textDelta(d))
                    case .done(let c, _, let u):
                        calls = c
                        turnUsage = u
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            }
            if let u = turnUsage {
                usage = usage.map {
                    LLMUsage(promptTokens: $0.promptTokens + u.promptTokens,
                             completionTokens: $0.completionTokens + u.completionTokens)
                } ?? u
            }
            finalText = text

            let assistantID = "m\(iteration)"
            messages.append(.assistant(text, calls: calls))
            sink(.assistantMessage(id: assistantID, text: text, calls: calls))

            if calls.isEmpty {
                sink(.finished(usage: usage))
                return RunResult(messages: messages, usage: usage, deniedCount: denied, finalText: finalText)
            }

            // -- Tool turns --
            for call in calls {
                if Task.isCancelled { throw CancellationError() }
                let preview = Self.preview(of: call)
                sink(.toolStarted(id: call.id, name: call.name, preview: preview))

                let (ok, denyReason) = await checkPermission(call: call)
                if !ok {
                    denied += 1
                    let msg = "Permission denied: \(denyReason). Do not retry the same action; tell the user what you wanted to do and why, and stop."
                    messages.append(.toolResult(id: call.id, name: call.name, output: msg))
                    sink(.toolFinished(id: call.id, name: call.name, ok: false,
                                       summary: "Denied by user", output: msg))
                    continue
                }

                let context = ToolContext(workspace: workspace, policy: policy,
                                          client: client, registry: registry,
                                          depth: 0, model: config.model,
                                          requestPermission: permissionGate)
                let executor = registry.tool(named: call.name)
                let result: ToolResult
                if let executor {
                    result = await executeWithTimeout(executor, args: call.arguments, context: context)
                } else {
                    result = ToolResult(output: "Error: unknown tool '\(call.name)'.")
                }

                if let todos = result.todos {
                    onTodos(todos)
                }
                if !result.files.isEmpty {
                    sink(.filesChanged(result.files))
                }
                let truncated = result.output.count > 40_000
                    ? String(result.output.suffix(40_000)) + "\n[result truncated]"
                    : result.output
                messages.append(.toolResult(id: call.id, name: call.name, output: truncated))
                sink(.toolFinished(id: call.id, name: call.name,
                                   ok: !result.output.hasPrefix("Error:"),
                                   summary: Self.summary(of: result.output),
                                   output: truncated))
            }
        }

        // Iteration budget exhausted: stop rather than loop forever.
        sink(.finished(usage: usage))
        return RunResult(messages: messages, usage: usage, deniedCount: denied, finalText: finalText)
    }

    // MARK: - Permission

    private func checkPermission(call: ToolCall) async -> (ok: Bool, reason: String) {
        switch call.name {
        case "write_file", "edit":
            let raw = JSONArgs.string(call.arguments, "file_path") ?? ""
            if case .proceed = policy.checkWrite(path: raw) { return (true, "") }
            if case .deny(let r) = policy.checkWrite(path: raw) { return (false, r) }
            let detail = "Write outside the project: \(policy.expand(raw))"
            let approved = await permissionGate(call.id, call.name, detail)
            return (approved, approved ? "" : "user declined")
        case "run_shell_command":
            let cmd = JSONArgs.string(call.arguments, "command") ?? ""
            if case .proceed = policy.checkShell(command: cmd) { return (true, "") }
            if case .deny(let r) = policy.checkShell(command: cmd) { return (false, r) }
            let detail = "Run command: \(cmd)"
            let approved = await permissionGate(call.id, call.name, detail)
            return (approved, approved ? "" : "user declined")
        default:
            return (true, "")
        }
    }

    // MARK: - Helpers

    private func executeWithTimeout(_ executor: any ToolExecutor,
                                    args: JSONString,
                                    context: ToolContext) async -> ToolResult {
        do {
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    await executor.execute(args: args, in: context)
                }
                group.addTask {
                    // Watchdog: fires the timeout; when it wins, the group
                    // cancels the executor task.
                    try await Task.sleep(nanoseconds: UInt64(config.toolTimeout) * 1_000_000_000)
                    return ToolResult(output: "Error: tool timed out after \(Int(config.toolTimeout))s.")
                }
                guard let first = try await group.next() else {
                    return ToolResult(output: "Error: tool produced no result.")
                }
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            return ToolResult(output: "Error: cancelled by user.")
        } catch {
            return ToolResult(output: "Error: tool failed: \(error.localizedDescription)")
        }
    }

    public static func preview(of call: ToolCall) -> String {
        switch call.name {
        case "read_file": return JSONArgs.string(call.arguments, "file_path") ?? call.name
        case "write_file", "edit":
            return JSONArgs.string(call.arguments, "file_path") ?? call.name
        case "run_shell_command": return JSONArgs.string(call.arguments, "command") ?? call.name
        case "web_fetch": return JSONArgs.string(call.arguments, "url") ?? call.name
        case "list_directory": return JSONArgs.string(call.arguments, "path") ?? call.name
        case "todo_write": return "update task list"
        case "agent":
            return JSONArgs.string(call.arguments, "description")
                ?? JSONArgs.string(call.arguments, "prompt").map { String($0.prefix(80)) }
                ?? "subagent"
        case "glob": return JSONArgs.string(call.arguments, "pattern") ?? call.name
        case "grep": return JSONArgs.string(call.arguments, "pattern") ?? call.name
        case "read_many_files": return JSONArgs.string(call.arguments, "paths") ?? call.name
        default:
            // Plugin tools: show the first string argument, which is nearly
            // always the interesting one.
            let args = JSONArgs.dictionary(call.arguments)
            if let first = args.sorted(by: { $0.key < $1.key }).compactMap({ $0.value as? String }).first,
               !first.isEmpty {
                return String(first.prefix(80))
            }
            return call.name
        }
    }

    public static func summary(of output: String) -> String {
        let first = output.split(separator: "\n").first.map(String.init) ?? output
        return String(first.prefix(120))
    }
}