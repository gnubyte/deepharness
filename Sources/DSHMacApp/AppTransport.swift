import Foundation
import Observation
import DSHCore

/// Drives agent sessions in-process: one `Engine` per conversation, its event
/// stream folded into the session's timeline, items mirrored to the
/// `ConversationLog`. This app IS the harness — no external process.
@MainActor
@Observable
public final class AppTransport {
    public let config: AppConfig
    public let log: ConversationLog

    public private(set) var sessions: [SessionVM] = []
    public var selectedID: String?
    public var banner: String?
    /// Plugin manifests loaded for the current project, and any that failed.
    public private(set) var plugins: [PluginManifest] = []
    public private(set) var pluginErrors: [String] = []
    /// Instruction files and skills the active project contributes.
    public private(set) var projectContext: ProjectContext?

    @ObservationIgnored private var engines: [String: Engine] = [:]
    @ObservationIgnored private var transcripts: [String: [LLMMessage]] = [:]
    @ObservationIgnored private var gates: [String: (cont: CheckedContinuation<Bool, Never>, sessionID: String)] = [:]
    @ObservationIgnored private var runTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let basePrompt: String
    /// Called when tools touch files, so the code-mode editor can reload.
    @ObservationIgnored public var onFilesChanged: (([FileChange]) -> Void)?

    public init(config: AppConfig, log: ConversationLog = .shared, systemPrompt: String? = nil) {
        self.config = config
        self.log = log
        self.basePrompt = systemPrompt ?? Self.defaultSystemPrompt
        reload()
    }

    public var selected: SessionVM? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    public var runningSessions: [SessionVM] { sessions.filter(\.running) }

    public static let defaultSystemPrompt = """
    You are a capable coding agent running inside a native macOS app, working in the user's project folder.

    Use the tools to read, write, and search files and to run shell commands. Prefer small, verifiable steps:
    read before you edit, and check your work after you change something. When a task needs more than a
    couple of steps, track it with `todo_write` so the user can see the plan.

    Rules that matter:
    - Never claim a command succeeded unless you ran it and saw the output.
    - Prefer `edit` over `write_file` for changes to an existing file; rewriting a whole file loses work.
    - Paths are resolved against the project folder. Stay inside it unless the user asks otherwise.
    - When you finish, summarize what changed in a few lines. Reference files as `path:line`.
    """

    // MARK: - Project

    /// Adopt a project folder: reload its plugins, instructions, and skills.
    public func adoptProject(_ url: URL?) {
        guard let url else {
            projectContext = nil
            plugins = []
            pluginErrors = []
            return
        }
        projectContext = ProjectContext.load(root: url)
        let loaded = PluginLoader.load(project: url)
        plugins = loaded.plugins
        pluginErrors = loaded.errors
        // Sessions pick the new context up on their next turn.
        engines.removeAll()
    }

    /// Re-read instructions, skills, and plugins from disk.
    public func refreshProjectContext() {
        adoptProject(projectContext?.root)
    }

    // MARK: - Sessions

    @discardableResult
    public func newSession(cwd: String?, preset: PermissionPreset? = nil) -> SessionVM {
        let id = UUID().uuidString
        let resolved = preset ?? config.asPreset
        let vm = SessionVM(id: id, title: "New chat", cwd: cwd, preset: resolved)
        sessions.insert(vm, at: 0)
        log.upsert(id: id, cwd: cwd, title: "New chat", preset: resolved.rawValue)
        selectedID = id
        return vm
    }

    public func deleteSession(_ id: String) {
        resolveAllGates(for: id, with: false)
        runTasks[id]?.cancel()
        runTasks[id] = nil
        engines[id] = nil
        transcripts[id] = nil
        log.delete(id)
        sessions.removeAll { $0.id == id }
        if selectedID == id { selectedID = sessions.first?.id }
    }

    public func renameSession(_ id: String, to title: String) {
        guard let vm = sessions.first(where: { $0.id == id }) else { return }
        vm.title = title
        log.touch(id, title: title)
    }

    public func reload() {
        let stored = log.list().compactMap { row -> SessionVM? in
            guard !sessions.contains(where: { $0.id == row.id }) else { return nil }
            let cwd = (row.cwd?.isEmpty ?? true) ? nil : row.cwd
            let vm = SessionVM(id: row.id, title: row.title, cwd: cwd,
                               preset: PermissionPreset(rawValue: row.preset ?? "") ?? .workspaceWrite)
            vm.updatedAt = row.updatedAt
            return vm
        }
        sessions = stored + sessions
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if selectedID == nil { selectedID = sessions.first?.id }
        if let selected { hydrate(selected) }
    }

    /// Replay a stored transcript into a session's timeline. Called lazily, so
    /// a long session list stays cheap to open.
    public func hydrate(_ vm: SessionVM) {
        guard vm.entries.isEmpty else { return }
        for row in log.loadItems(vm.id) {
            switch row.kind {
            case "user": vm.appendMessage(.user, row.text ?? "", at: row.at)
            case "assistant": vm.appendMessage(.assistant, row.text ?? "", at: row.at)
            case "notice": vm.appendMessage(.notice, row.text ?? "", at: row.at)
            case "error": vm.appendMessage(.error, row.text ?? "", at: row.at)
            case "tool":
                vm.addFinishedTool(id: "log-\(row.seq)", name: row.toolName ?? "tool",
                                   preview: row.argSummary ?? "", summary: row.text,
                                   output: row.output, ok: !row.isError, at: row.at)
            default: break
            }
        }
        // A hydrated session has no live engine; rebuild the model transcript
        // so a follow-up turn keeps the conversation rather than starting over.
        if transcripts[vm.id] == nil {
            transcripts[vm.id] = Self.replayMessages(vm.entries)
        }
    }

    /// Reconstruct a model-facing transcript from a rendered one. Tool calls
    /// are folded into the assistant text: replaying their exact call ids is
    /// not worth persisting, and the model only needs to know what happened.
    static func replayMessages(_ entries: [ChatEntry]) -> [LLMMessage] {
        var out: [LLMMessage] = []
        var pendingTools: [String] = []

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            out.append(.assistant("[earlier tool activity]\n" + pendingTools.joined(separator: "\n")))
            pendingTools = []
        }

        for entry in entries {
            switch entry.kind {
            case .message(let body):
                switch body.role {
                case .user:
                    flushTools()
                    out.append(.user(body.text))
                case .assistant:
                    flushTools()
                    out.append(.assistant(body.text))
                case .notice, .error:
                    continue
                }
            case .tool(let activity):
                let head = "\(activity.name)(\(activity.preview))"
                pendingTools.append("- \(head) → \(activity.summary ?? (activity.isOk == false ? "failed" : "ok"))")
            case .todos:
                continue
            }
        }
        flushTools()
        return out
    }

    // MARK: - Engine

    private func engine(for sessionID: String, vm: SessionVM, client: any LLMClient) -> Engine {
        let workspace = vm.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
        let policy = PermissionPolicy(preset: vm.preset, workspaceRoot: workspace)
        let model = (client as? OpenAIClient)?.profile.model ?? "model"

        // Project instructions + skills + plugin tools are what make this a
        // harness rather than a chat window.
        let context = projectContext?.root == workspace ? projectContext : ProjectContext.load(root: workspace)
        let environment = ProjectContext.environmentBlock(workspace: workspace, model: model, preset: vm.preset)
        var prompt = basePrompt
        if let context {
            prompt += "\n\n" + context.promptSupplement(environment: environment)
        } else {
            prompt += "\n\n" + environment
        }
        if vm.preset == .plan {
            prompt += """


            --- Plan mode ---
            Do not modify anything. Research and produce a plan, then call `exit_plan_mode` with it and stop.
            """
        }

        let builtins = ToolRegistry.standard()
        let registry = builtins.adding(
            PluginLoader.tools(from: plugins, reserved: Set(builtins.names))
        )

        let engine = Engine(
            client: client,
            registry: registry,
            systemPrompt: prompt,
            config: .init(model: model,
                          temperature: (client as? OpenAIClient)?.profile.temperature,
                          maxOutputTokens: (client as? OpenAIClient)?.profile.maxOutputTokens),
            workspace: workspace,
            policy: policy,
            permissionGate: { [weak self] id, name, detail in
                guard let self else { return false }
                return await self.askGate(sessionID: sessionID, gateID: id, name: name, detail: detail)
            },
            onTodos: { [weak self] todos in
                Task { @MainActor [weak self] in
                    self?.sessions.first { $0.id == sessionID }?.setTodos(todos)
                }
            }
        )
        engines[sessionID] = engine
        return engine
    }

    /// Bridge `Engine.permissionGate` to the UI: publish the gate on the
    /// session and await the user's answer.
    private func askGate(sessionID: String, gateID: String, name: String, detail: String) async -> Bool {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return false }
        vm.pendingGates.removeAll { $0.id == gateID }
        vm.pendingGates.append(.init(id: gateID, name: name, detail: detail))
        let decision: Bool = await withCheckedContinuation { continuation in
            gates[gateID] = (continuation, sessionID)
        }
        gates[gateID] = nil
        vm.pendingGates.removeAll { $0.id == gateID }
        return decision
    }

    /// Answer a pending gate from the UI.
    public func answerGate(sessionID: String, gateID: String, allow: Bool) {
        guard let entry = gates[gateID] else { return }
        gates[gateID] = nil
        entry.cont.resume(returning: allow)
        sessions.first { $0.id == sessionID }?.pendingGates.removeAll { $0.id == gateID }
    }

    private func resolveAllGates(for sessionID: String, with allow: Bool) {
        for (gateID, entry) in gates where entry.sessionID == sessionID {
            gates[gateID] = nil
            entry.cont.resume(returning: allow)
        }
    }

    // MARK: - Sending

    public func send(_ text: String, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        guard !vm.running else {
            vm.note("The agent is still working; send again when it is done.")
            return
        }
        runTasks[sessionID] = Task { await runTurn(vm, text: text) }
    }

    private func runTurn(_ vm: SessionVM, text: String) async {
        let sessionID = vm.id
        vm.running = true
        vm.stopping = false
        defer {
            vm.running = false
            vm.stopping = false
            vm.endStreaming()
            runTasks[sessionID] = nil
            log.touch(sessionID)
            vm.updatedAt = .now
            sessions.sort { $0.updatedAt > $1.updatedAt }
        }

        vm.appendMessage(.user, text)
        log.recordItem(sessionID, kind: "user", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        if vm.title == "New chat" {
            let first = text.split(separator: "\n").first.map(String.init) ?? text
            let title = String(first.prefix(48))
            if !title.isEmpty { renameSession(sessionID, to: title) }
        }

        do {
            let client = try config.makeClient()
            let engine = engines[sessionID] ?? engine(for: sessionID, vm: vm, client: client)
            let input = transcripts[sessionID] ?? []

            // Engine events arrive on a pool thread; hop to main so the
            // timeline is only ever mutated from one place.
            let sink = self
            let result = try await engine.run(messages: input, userText: text) { event in
                Task { @MainActor in
                    sink.apply(event, sessionID: sessionID)
                }
            }
            transcripts[sessionID] = result.messages
            vm.lastUsage = result.usage
            if result.deniedCount > 0 {
                vm.note("\(result.deniedCount) tool call(s) were denied.")
            }
        } catch is CancellationError {
            vm.endStreaming()
            vm.note("Stopped.")
            log.recordItem(sessionID, kind: "notice", text: "Stopped.", toolName: nil, argSummary: nil, output: nil, isError: false)
        } catch {
            let message = Self.describe(error)
            vm.endStreaming()
            vm.note(message, role: .error)
            log.recordItem(sessionID, kind: "error", text: message, toolName: nil, argSummary: nil, output: nil, isError: true)
            banner = message
        }
    }

    private func apply(_ event: EngineEvent, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        switch event {
        case .textDelta(let chunk):
            vm.appendDelta(chunk)

        case .assistantMessage(_, let text, _):
            // Fold a turn's complete text if deltas never arrived, then close
            // the bubble so any tool calls render after it.
            if vm.streamingID == nil, !text.isEmpty {
                vm.appendMessage(.assistant, text)
            }
            if !text.isEmpty {
                log.recordItem(sessionID, kind: "assistant", text: text,
                               toolName: nil, argSummary: nil, output: nil, isError: false)
            }
            vm.endStreaming()

        case .toolStarted(let id, let name, let preview):
            vm.startTool(id: id, name: name, preview: preview)

        case .toolFinished(let id, let name, let ok, let summary, let output):
            vm.finishTool(id: id, ok: ok, summary: summary, output: output)
            log.recordItem(sessionID, kind: "tool", text: summary, toolName: name,
                           argSummary: vm.entries.last(where: { $0.id == id })?.tool?.preview,
                           output: output, isError: !ok)

        case .filesChanged(let changes):
            vm.recordFileChanges(changes)
            onFilesChanged?(changes)

        case .finished(let usage):
            vm.lastUsage = usage
            vm.endStreaming()

        case .permissionQuestion(let id, let name, let detail):
            if !vm.pendingGates.contains(where: { $0.id == id }) {
                vm.pendingGates.append(.init(id: id, name: name, detail: detail))
            }

        case .todos(let todos):
            vm.setTodos(todos)

        case .failed(let message):
            vm.note(message, role: .error)
            banner = message
        }
    }

    // MARK: - Stopping

    public func stopSession(_ id: String) {
        sessions.first { $0.id == id }?.stopping = true
        resolveAllGates(for: id, with: false)
        runTasks[id]?.cancel()
    }

    public func stopAll() {
        for id in runTasks.keys { stopSession(id) }
    }

    public func note(_ message: String) { banner = message }

    public static func describe(_ error: Error) -> String {
        if let llm = error as? LLMError {
            return llm.errorDescription ?? "\(llm)"
        }
        return error.localizedDescription
    }
}
