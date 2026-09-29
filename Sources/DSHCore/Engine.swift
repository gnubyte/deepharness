import Foundation

// MARK: - Engine events (observed by the UI)

public enum EngineEvent: Sendable {
    /// A chunk of assistant text arrived.
    case textDelta(String)
    /// A chunk of the model's reasoning arrived (shown live, not kept).
    case reasoningDelta(String)
    /// The assistant's message for this turn is complete (text + any tool calls).
    case assistantMessage(id: String, text: String, calls: [ToolCall])
    /// A tool call is about to execute.
    case toolStarted(id: String, name: String, preview: String)
    /// A tool call finished. `summary` is a one-line headline; `output` is the
    /// full (already length-capped) result the UI reveals on demand.
    case toolFinished(id: String, name: String, ok: Bool, summary: String, output: String)
    /// Images a tool produced (screenshots, frames); the UI shows them on the tool card.
    case toolImages(id: String, images: [MessageAttachment])
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
    /// A model call failed for a reason that can fix itself (timeout, server
    /// down/restarting/swapping, overloaded); the engine waits `delay` seconds
    /// and tries again. Any text streamed by the failed attempt is void — the
    /// retry streams the reply from the start.
    case retrying(attempt: Int, delay: TimeInterval, reason: String)
    /// A model call succeeded after `attempts` failed tries.
    case recovered(attempts: Int)
}

/// Everything a run returns to its caller.
public struct RunResult: Sendable {
    /// Full message list, ready to feed back next run.
    public let messages: [LLMMessage]
    public let usage: LLMUsage?
    public let deniedCount: Int
    /// The assistant text of the final turn (empty if the run was cut off mid-tools).
    public let finalText: String
    /// Prompt tokens on the final model call — a good measure of how full the
    /// context is now. Nil when the server didn't report per-request usage.
    public let lastPromptTokens: Int?
    /// True when the run stopped because it used its whole iteration budget
    /// while the model still wanted to call tools (it did not finish).
    public let hitIterationLimit: Bool
    /// The last non-empty assistant text of the run. Usually `finalText`, but
    /// when the model wrote its conclusion alongside a last tool call and then
    /// ended with an empty message, this still carries the conclusion.
    public let lastReplyText: String

    public init(messages: [LLMMessage], usage: LLMUsage?, deniedCount: Int,
                finalText: String, lastPromptTokens: Int? = nil, hitIterationLimit: Bool = false,
                lastReplyText: String? = nil) {
        self.messages = messages
        self.usage = usage
        self.deniedCount = deniedCount
        self.finalText = finalText
        self.lastPromptTokens = lastPromptTokens
        self.hitIterationLimit = hitIterationLimit
        self.lastReplyText = lastReplyText ?? finalText
    }
}

/// A live copy of the transcript while a run is in flight. When a run throws
/// or is cancelled part-way, the caller keeps the work that already happened
/// (tool calls that ran and their results) instead of rolling the model's
/// memory back to before the run while the files on disk moved on.
public final class RunProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [LLMMessage]?
    /// Something beyond the run's own user message happened (a reply, a tool
    /// result, a compaction) — tracked as a flag, not by length, because an
    /// in-run compaction shrinks the list below where it started.
    private var progressed = false

    public init() {}

    func begin(baseCount: Int) {
        lock.lock(); defer { lock.unlock() }
        latest = nil
        progressed = false
    }

    func update(_ messages: [LLMMessage], progressed: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        latest = messages
        if progressed { self.progressed = true }
    }

    /// The transcript to keep after an interrupted run, or nil when the run got
    /// no further than its own user message (nothing worth keeping — and two
    /// user messages in a row upset strict chat templates). Tool calls left
    /// without a result are closed with a stub so the transcript stays a valid
    /// request.
    public var salvaged: [LLMMessage]? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, progressed else { return nil }
        return Engine.closingDanglingToolCalls(latest)
    }
}


public struct EngineConfig: Sendable {
    public var maxIterations: Int
    public var toolTimeout: TimeInterval
    public var model: String
    public var temperature: Double?
    public var maxOutputTokens: Int?
    /// The model's context window in tokens. When set, the run auto-compacts
    /// the transcript as it approaches the limit (see `Engine.compaction`).
    /// Nil disables in-run compaction.
    public var contextWindow: Int?
    /// How many times one run may compact, as a runaway guard (0 = never).
    public var maxCompactions: Int
    /// Thinking level sent with every model call; nil = the provider default.
    public var thinking: ThinkingLevel?
    /// How many tool-image messages (screenshots, frames) stay in the request;
    /// older ones are replaced by a short note so a long debugging session
    /// doesn't fill the window with stale pictures.
    public var maxToolImageMessages: Int
    /// False when the model can't take images: tool images are dropped and the
    /// tool result says so, so the agent falls back to text (logs, ui_tree).
    public var visionEnabled: Bool
    /// How model calls that fail transiently (timeouts, server down, overloaded)
    /// are retried. Standard: indefinitely, with backoff, until cancelled.
    public var retry: RetryPolicy

    public init(maxIterations: Int = 30, toolTimeout: TimeInterval = 300,
                model: String, temperature: Double? = nil, maxOutputTokens: Int? = nil,
                contextWindow: Int? = nil, maxCompactions: Int = 4,
                thinking: ThinkingLevel? = nil,
                maxToolImageMessages: Int = 3, visionEnabled: Bool = true,
                retry: RetryPolicy = .standard) {
        self.maxIterations = maxIterations
        self.toolTimeout = toolTimeout
        self.model = model
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.contextWindow = contextWindow
        self.maxCompactions = maxCompactions
        self.thinking = thinking
        self.maxToolImageMessages = maxToolImageMessages
        self.visionEnabled = visionEnabled
        self.retry = retry
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
    /// Optional auto-compaction hook: given the current request size and the
    /// transcript, returns a smaller transcript (older messages replaced by a
    /// summary) when it is over budget. When nil, or when it throws/returns the
    /// input unchanged, the run proceeds as-is.
    public let compaction: (@Sendable (_ used: Int, _ transcript: [LLMMessage]) async throws -> [LLMMessage])?
    /// Screen/computer approvals for this chat (persist across engine rebuilds).
    public let computerGrants: ComputerGrants
    /// Called before each retry of a failed model call: the host re-resolves
    /// the route (the server may have swapped models, or the user fixed the
    /// provider in Settings) and returns the client + model id to use from now
    /// on, or nil to keep the current ones.
    public let reroute: (@Sendable () async -> (client: any LLMClient, model: String)?)?
    /// Credentials the agent can use as `{{vault:NAME}}` (substituted when a
    /// tool runs, scrubbed from every tool result), and this chat's approvals.
    public let vault: CredentialVault?
    public let vaultGrants: VaultGrants

    public init(client: any LLMClient,
                registry: ToolRegistry,
                systemPrompt: String,
                config: EngineConfig,
                workspace: URL,
                policy: PermissionPolicy,
                permissionGate: @escaping @Sendable (String, String, String) async -> Bool,
                onTodos: @escaping @Sendable ([TodoItem]) -> Void = { _ in },
                compaction: (@Sendable (Int, [LLMMessage]) async throws -> [LLMMessage])? = nil,
                computerGrants: ComputerGrants = ComputerGrants(),
                reroute: (@Sendable () async -> (client: any LLMClient, model: String)?)? = nil,
                vault: CredentialVault? = nil,
                vaultGrants: VaultGrants = VaultGrants()) {
        self.client = client
        self.registry = registry
        self.systemPrompt = systemPrompt
        self.config = config
        self.workspace = workspace
        self.policy = policy
        self.permissionGate = permissionGate
        self.onTodos = onTodos
        self.compaction = compaction
        self.computerGrants = computerGrants
        self.reroute = reroute
        self.vault = vault
        self.vaultGrants = vaultGrants
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
    /// Emits events to `sink` as they happen. `progress`, when given, tracks
    /// the transcript as it grows so a caller whose run throws can keep the
    /// work already done (see `RunProgress.salvaged`).
    @discardableResult
    public func run(messages input: [LLMMessage],
                    userText: String,
                    userAttachments: [MessageAttachment] = [],
                    progress: RunProgress? = nil,
                    sink: @escaping @Sendable (EngineEvent) -> Void) async throws -> RunResult {
        var messages = input
        progress?.begin(baseCount: input.count)
        if !userText.isEmpty || !userAttachments.isEmpty {
            messages.append(.user(userText,
                                  attachments: userAttachments.isEmpty ? nil : userAttachments))
        }
        progress?.update(messages, progressed: false)
        var usage: LLMUsage? = nil
        var denied = 0
        var finalText = ""
        var lastReplyText = ""
        var lastPromptTokens: Int? = nil
        var compacted = 0
        // The route can change under a long run: a retry after the Spark
        // swapped models continues on whatever it serves now.
        var client = self.client
        var model = config.model

        for iteration in 0..<config.maxIterations {
            if Task.isCancelled { throw CancellationError() }

            // -- Model turn (retried while the server is unavailable) --
            var text = ""
            var calls: [ToolCall] = []
            var turnUsage: LLMUsage? = nil
            var failures = 0
            // HTTP 500s get a bounded number of tries of their own — counted
            // apart from outage retries, so a 500 after a long outage still
            // gets its full allowance.
            var limitedFailures = 0
            modelCall: while true {
                if Task.isCancelled { throw CancellationError() }

                // Auto-compaction: keep the request inside the context window.
                // Re-checked on every attempt — a retry after an outage may
                // still need it, and a failed summarizer gets another chance.
                if let window = config.contextWindow, window > 0,
                   compaction != nil, compacted < config.maxCompactions {
                    let used = TokenEstimate.request(systemPrompt: systemPrompt, messages: messages)
                    if used >= Int(Double(window) * Compaction.triggerFraction) {
                        do {
                            let out = try await compaction!(used, messages)
                            if out.count < messages.count {
                                messages = out
                                compacted += 1
                                progress?.update(messages)
                            }
                        } catch {
                            // Compaction failed: proceed as-is; a server overflow is
                            // the second line of defence below.
                        }
                    }
                }
                if Task.isCancelled { throw CancellationError() }

                Self.pruneToolImages(&messages, keep: config.maxToolImageMessages)

                let request = LLMRequest(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: registry.specs,
                    model: model,
                    temperature: config.temperature,
                    maxTokens: config.maxOutputTokens,
                    thinking: config.thinking
                )

                text = ""
                calls = []
                turnUsage = nil
                do {
                    for try await event in client.stream(request) {
                        if Task.isCancelled { throw CancellationError() }
                        switch event {
                        case .text(let d):
                            text += d
                            sink(.textDelta(d))
                        case .reasoning(let r):
                            sink(.reasoningDelta(r))
                        case .done(let c, _, let u):
                            calls = c
                            turnUsage = u
                        }
                    }
                    // A stream cancelled by Stop ends quietly rather than
                    // throwing; its partial text must not pass as a reply.
                    if Task.isCancelled { throw CancellationError() }
                    // Only a reply that arrived whole counts as recovery — a
                    // stream that starts and is cut off again is another failure.
                    if failures > 0 { sink(.recovered(attempts: failures)) }
                    break modelCall
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    // The server said the request overflowed its real window. If we
                    // can still compact, do it and retry this call.
                    if case LLMError.overflow = error,
                       compaction != nil, compacted < config.maxCompactions {
                        // The server's word beats our estimate (which undercounts
                        // code and JSON): report at least a full window so the
                        // hook compacts even when the estimate looks fine.
                        let used = max(TokenEstimate.request(systemPrompt: systemPrompt, messages: messages),
                                       config.contextWindow ?? 0)
                        if let out = try? await compaction!(used, messages), out.count < messages.count {
                            messages = out
                            compacted += 1
                            progress?.update(messages)
                            continue modelCall
                        }
                    }
                    // Timeouts, a server that is down/restarting/swapping/busy:
                    // wait and try again until it answers or the user stops.
                    failures += 1
                    if case .limited = RequestRetry.disposition(for: error) { limitedFailures += 1 }
                    guard config.retry.shouldRetry(error, attempt: max(1, limitedFailures)) else { throw error }
                    let delay = max(0, config.retry.delay(failures))
                    sink(.retrying(attempt: failures, delay: delay, reason: RequestRetry.reason(for: error)))
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    if Task.isCancelled { throw CancellationError() }
                    if let reroute, let route = await reroute() {
                        client = route.client
                        if !route.model.isEmpty { model = route.model }
                    }
                }
            }

            if let u = turnUsage {
                usage = usage.map {
                    LLMUsage(promptTokens: $0.promptTokens + u.promptTokens,
                             completionTokens: $0.completionTokens + u.completionTokens)
                } ?? u
            }
            if let u = turnUsage { lastPromptTokens = u.promptTokens }
            finalText = text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastReplyText = text }

            let assistantID = "m\(iteration)"
            messages.append(.assistant(text, calls: calls))
            progress?.update(messages)
            sink(.assistantMessage(id: assistantID, text: text, calls: calls))

            if calls.isEmpty {
                sink(.finished(usage: usage))
                return RunResult(messages: messages, usage: usage, deniedCount: denied,
                                 finalText: finalText, lastPromptTokens: lastPromptTokens,
                                 lastReplyText: lastReplyText)
            }

            // -- Tool turns --
            var toolImages: [(tool: String, images: [MessageAttachment])] = []
            for call in calls {
                if Task.isCancelled { throw CancellationError() }
                let preview = Self.preview(of: call)
                sink(.toolStarted(id: call.id, name: call.name, preview: preview))

                let (ok, denyReason) = await checkPermission(call: call)
                // Stop resolves a pending question as "no": that is not the
                // user declining, so don't record it as a refusal.
                if Task.isCancelled { throw CancellationError() }
                if !ok {
                    denied += 1
                    let msg = "Permission denied: \(denyReason). Do not retry the same action; tell the user what you wanted to do and why, and stop."
                    messages.append(.toolResult(id: call.id, name: call.name, output: msg))
                    progress?.update(messages)
                    sink(.toolFinished(id: call.id, name: call.name, ok: false,
                                       summary: "Denied by user", output: msg))
                    continue
                }

                // Credentials: {{vault:NAME}} becomes the real value only now,
                // after the permission check saw the placeholder.
                var arguments = call.arguments
                switch await resolveVault(for: call) {
                case .none:
                    break
                case .substituted(let raw):
                    arguments = JSONString(raw)
                case .refused(let msg):
                    if Task.isCancelled { throw CancellationError() }
                    messages.append(.toolResult(id: call.id, name: call.name, output: msg))
                    progress?.update(messages)
                    sink(.toolFinished(id: call.id, name: call.name, ok: false,
                                       summary: Self.summary(of: msg), output: msg))
                    continue
                }
                if Task.isCancelled { throw CancellationError() }

                let context = ToolContext(workspace: workspace, policy: policy,
                                          client: client, registry: registry,
                                          depth: 0, model: model,
                                          contextWindow: config.contextWindow,
                                          thinking: config.thinking,
                                          requestPermission: permissionGate,
                                          vault: vault, vaultGrants: vaultGrants)
                let executor = registry.tool(named: call.name)
                let result: ToolResult
                if let executor {
                    result = await executeWithTimeout(executor, args: arguments, context: context)
                } else {
                    result = ToolResult(output: "Error: unknown tool '\(call.name)'.")
                }

                if let todos = result.todos {
                    onTodos(todos)
                }
                // No vault value ever reaches the model, the timeline or the logs.
                let secrets = vault?.valuesForRedaction() ?? []
                var resultOutput = secrets.isEmpty ? result.output : VaultPlaceholders.redact(result.output, values: secrets)
                if !result.images.isEmpty {
                    if config.visionEnabled {
                        toolImages.append((call.name, result.images))
                        sink(.toolImages(id: call.id, images: result.images))
                    } else {
                        resultOutput += "\n(\(result.images.count) image(s) not shown: the selected model can't take images. Use text tools — ui_tree, process_read, logs — instead.)"
                    }
                }
                if !result.files.isEmpty {
                    sink(.filesChanged(result.files))
                }
                let truncated = resultOutput.count > 40_000
                    ? String(resultOutput.suffix(40_000)) + "\n[result truncated]"
                    : resultOutput
                messages.append(.toolResult(id: call.id, name: call.name, output: truncated))
                progress?.update(messages)
                sink(.toolFinished(id: call.id, name: call.name,
                                   ok: !resultOutput.hasPrefix("Error:"),
                                   summary: Self.summary(of: resultOutput),
                                   output: truncated))
            }

            // Chat-completion tool messages are text-only, so what the tools
            // captured goes back on one attached user message, after every
            // tool result of this turn (tool answers must stay contiguous).
            if !toolImages.isEmpty {
                let all = toolImages.flatMap(\.images)
                let names = Array(Set(toolImages.map(\.tool))).sorted().joined(separator: ", ")
                messages.append(LLMMessage(
                    role: .user,
                    content: "[Automatic message: \(all.count) image(s) captured by \(names). Not from the user — this is what the tool saw.]",
                    attachments: all,
                    imageSource: names))
                progress?.update(messages)
            }
        }

        // Iteration budget exhausted: stop rather than loop forever.
        sink(.finished(usage: usage))
        return RunResult(messages: messages, usage: usage, deniedCount: denied,
                         finalText: finalText, lastPromptTokens: lastPromptTokens,
                         hitIterationLimit: true, lastReplyText: lastReplyText)
    }

    /// Close tool calls that never got a result (the run was interrupted
    /// between the model asking and the tool answering) with a stub, so the
    /// transcript is a valid request again — servers reject an assistant
    /// tool call with no matching tool message.
    public static func closingDanglingToolCalls(_ messages: [LLMMessage]) -> [LLMMessage] {
        guard let last = messages.lastIndex(where: { $0.role == .assistant }),
              let calls = messages[last].toolCalls, !calls.isEmpty else { return messages }
        let after = messages[(last + 1)...]
        // Anything but tool results after it means the block was closed already.
        guard after.allSatisfy({ $0.role == .tool }) else { return messages }
        let answered = Set(after.compactMap(\.toolCallID))
        var out = messages
        for call in calls where !answered.contains(call.id) {
            out.append(.toolResult(id: call.id, name: call.name,
                                   output: "Not run — the turn was interrupted before this call executed."))
        }
        return out
    }

    // MARK: - Vault

    enum VaultResolution { case none, substituted(String), refused(String) }

    /// Resolve the `{{vault:NAME}}` placeholders in a call: unknown names and
    /// credentials the user withheld refuse the call; "ask first" asks once
    /// per chat; the rest are substituted into the arguments.
    func resolveVault(for call: ToolCall) async -> VaultResolution {
        guard let vault else { return .none }
        let names = VaultPlaceholders.names(in: call.arguments.raw)
        guard !names.isEmpty else { return .none }
        var values: [String: String] = [:]
        for name in names {
            switch vault.lookup(name) {
            case .missing:
                return .refused("Error: there is no credential named \(name) in the vault. Use vault_search to see what's there; if it's missing, ask the user to add it to the Credentials Vault (⌘⇧K) — never to paste it into chat.")
            case .value(let value, let access):
                switch access {
                case .never:
                    return .refused("Error: the user has made the credential \(name) unavailable to the agent. Tell them what you needed it for.")
                case .ask where !vaultGrants.has(name):
                    let approved = await permissionGate(call.id, call.name, "Use the credential \(name) from the vault in \(call.name)")
                    guard approved else {
                        return .refused("Permission denied: the user did not allow \(name) to be used. Don't retry with it; say what you needed it for.")
                    }
                    vaultGrants.grant(name)
                case .ask, .allowed:
                    break
                }
                values[name] = value
            }
        }
        names.forEach { vault.noteUse($0) }
        return .substituted(VaultPlaceholders.substitute(in: call.arguments.raw, values: values))
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
        case "process_start":
            // Starting a background process is running a shell command.
            let cmd = JSONArgs.string(call.arguments, "command") ?? ""
            return await shellGate(call: call, command: cmd, detailPrefix: "Start background process")
        case "process_write":
            // Input to a running process can be a command to its shell.
            let input = JSONArgs.string(call.arguments, "input") ?? ""
            return await shellGate(call: call, command: input, detailPrefix: "Send to background process")
        default:
            if let access = ComputerAccess.forTool(call.name) {
                return await computerGate(access, call: call)
            }
            return (true, "")
        }
    }

    private func shellGate(call: ToolCall, command: String, detailPrefix: String) async -> (ok: Bool, reason: String) {
        if case .proceed = policy.checkShell(command: command) { return (true, "") }
        if case .deny(let r) = policy.checkShell(command: command) { return (false, r) }
        let approved = await permissionGate(call.id, call.name, "\(detailPrefix): \(command)")
        return (approved, approved ? "" : "user declined")
    }

    private func computerGate(_ access: ComputerAccess, call: ToolCall) async -> (ok: Bool, reason: String) {
        switch policy.checkComputer(access) {
        case .proceed: return (true, "")
        case .deny(let r): return (false, r)
        case .ask:
            if computerGrants.has(access) { return (true, "") }
            let approved = await permissionGate(call.id, call.name, access.prompt)
            if approved { computerGrants.grant(access) }
            return (approved, approved ? "" : "user declined")
        }
    }

    // MARK: - Helpers

    /// Replace all but the newest `keep` tool-image messages with a short
    /// note. Images the user attached themselves are never touched.
    public static func pruneToolImages(_ messages: inout [LLMMessage], keep: Int) {
        var seen = 0
        for index in messages.indices.reversed() {
            guard messages[index].imageSource != nil, let atts = messages[index].attachments, !atts.isEmpty else { continue }
            seen += 1
            if seen > max(0, keep) {
                messages[index].attachments = nil
                messages[index].content = "[\(atts.count) earlier image(s) from \(messages[index].imageSource ?? "a tool") removed to save context — capture again if you need to see it.]"
            }
        }
    }

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