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
    /// AI-generated, agent-proposed and imported skills waiting for approval.
    public private(set) var pendingDrafts: [SkillDraft] = []
    /// Bumped whenever skills change on disk through the app, so open views reload.
    public private(set) var skillsRevision = 0
    @ObservationIgnored public let skillLocations = SkillLocations.standard

    @ObservationIgnored private var engines: [String: Engine] = [:]
    /// What each session's engine was built with; a mismatch rebuilds it
    /// (provider or served model changed, window re-detected, thinking level).
    @ObservationIgnored private var engineKeys: [String: EngineKey] = [:]
    @ObservationIgnored private var transcripts: [String: [LLMMessage]] = [:]
    @ObservationIgnored private var gates: [String: (cont: CheckedContinuation<Bool, Never>, sessionID: String)] = [:]
    @ObservationIgnored private var runTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let basePrompt: String
    /// Route ID → context window (tokens) learned from a server probe.
    /// Observed, so the context gauge redraws the moment a probe lands.
    private var probedContext: [String: Int] = [:]
    /// Route ID → what the server said it serves, and when we last asked.
    private var routeInfo: [String: RouteInfo] = [:]
    /// Route IDs whose probe is already in flight (avoids duplicate requests).
    @ObservationIgnored private var probingContext: Set<String> = []

    struct RouteInfo: Hashable {
        var servedModel: String
        var servedModels: [String]
        var context: Int?
        var at: Date
    }

    struct EngineKey: Hashable {
        var profile: ProviderProfile
        var window: Int
        var thinking: ThinkingLevel?
        var preset: PermissionPreset
        /// Hash of the skills in the prompt and the tools they enable.
        var skills: Int
        var computerTools: Bool
        var vision: Bool
    }

    /// Everything about skills one turn needs: what exists, what's on, and the prompt text.
    struct SkillState {
        let all: [Skill]
        let active: [Skill]
        let result: SkillPromptResult
        let signature: Int
    }
    /// Route ID → the fully-built system prompt (base + project context +
    /// preset), cached so the context gauge's token estimate reads a string
    /// instead of re-loading project files on every keystroke.
    @ObservationIgnored private var systemPrompts: [String: String] = [:]
    /// Called when tools touch files, so the code-mode editor can reload.
    @ObservationIgnored public var onFilesChanged: (([FileChange]) -> Void)?
    /// True while the model server is switching models (Spark swapper).
    @ObservationIgnored var isServerSwitching: (() -> Bool)?
    /// Handles `/swap [model]`.
    @ObservationIgnored var onSwapCommand: ((String?, SessionVM) -> Void)?

    /// Post a notice into the chat the user is looking at.
    func broadcast(_ text: String, error: Bool = false) {
        guard let vm = selected else { banner = text; return }
        vm.note(text, role: error ? .error : .notice)
        log.recordItem(vm.id, kind: error ? "error" : "notice", text: text, toolName: nil,
                       argSummary: nil, output: nil, isError: error)
    }

    public init(config: AppConfig, log: ConversationLog = .shared, systemPrompt: String? = nil) {
        self.config = config
        self.log = log
        self.basePrompt = systemPrompt ?? Self.defaultSystemPrompt
        // Ship-with-the-app skills (godot-debugging, …) refresh on every launch.
        try? SkillBuiltin.install(into: skillLocations.builtinSkills)
        reload()
        refreshDrafts()
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
        systemPrompts.removeAll()
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
        engineKeys[id] = nil
        config.sessionSkills[id] = nil
        transcripts[id] = nil
        systemPrompts[id] = nil
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
            case "compaction":
                let removed = Int(row.argSummary ?? "") ?? 0
                vm.entries.append(ChatEntry(at: row.at, kind: .compaction(
                    .init(removed: removed, summary: row.text ?? "", at: row.at))))
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
            case .compaction(let note):
                // A compacted transcript starts from its summary: everything
                // above the divider is already folded into it.
                pendingTools = []
                out = [.system(Compaction.summaryHeader + note.summary)]
            }
        }
        flushTools()
        return out
    }

    // MARK: - Engine

    private func engine(for sessionID: String, vm: SessionVM, client: any LLMClient,
                        window: Int, thinking: ThinkingLevel?, skillState: SkillState) -> Engine {
        let workspace = vm.workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
        let policy = PermissionPolicy(preset: vm.preset, workspaceRoot: workspace)
        let model = (client as? OpenAIClient)?.profile.model ?? "model"

        // Project instructions + skills + plugin tools are what make this a
        // harness rather than a chat window.
        let context = projectContext?.root == workspace ? projectContext : ProjectContext.load(root: workspace)
        let environment = ProjectContext.environmentBlock(workspace: workspace, model: model, preset: vm.preset)
        var prompt = basePrompt
        if let context {
            prompt += "\n\n" + context.promptSupplement(environment: environment, includeSkills: false)
        } else {
            prompt += "\n\n" + environment
        }
        // Skills: always-on rules, the ones the user selected for this chat,
        // and a catalog the model can load from with `use_skill`.
        if !skillState.result.text.isEmpty { prompt += "\n\n" + skillState.result.text }
        if vm.preset == .plan {
            prompt += """


            --- Plan mode ---
            Do not modify anything. Research and produce a plan, then call `exit_plan_mode` with it and stop.
            """
        }
        systemPrompts[sessionID] = prompt

        let builtins = ToolRegistry.standard()
        var extra: [any ToolExecutor] = PluginLoader.tools(from: plugins, reserved: Set(builtins.names))
        if !skillState.active.isEmpty { extra.append(UseSkillTool(skills: skillState.active)) }
        if vm.preset != .plan {
            extra.append(ProposeSkillTool(projectRoot: vm.workspaceURL, locations: skillLocations))
        }
        // Background processes: the model's own long-running programs (game
        // engines, dev servers, REPLs) that keep running between tool calls.
        extra.append(contentsOf: ToolRegistry.processes())
        // Seeing/steering the machine — screenshots, windows, a11y trees,
        // clicks, keystrokes. Off with the computerToolsEnabled kill switch;
        // each first use in a chat still asks (Engine.computerGate).
        if config.computerToolsEnabled {
            extra.append(contentsOf: ToolRegistry.machineTools())
        }
        let registry = builtins.adding(extra)

        let engine = Engine(
            client: client,
            registry: registry,
            systemPrompt: prompt,
            config: .init(model: model,
                          temperature: (client as? OpenAIClient)?.profile.temperature,
                          maxOutputTokens: (client as? OpenAIClient)?.profile.maxOutputTokens,
                          contextWindow: window,
                          thinking: thinking,
                          visionEnabled: visionOn(for: (client as? OpenAIClient)?.profile)),
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
            },
            compaction: { [weak self] used, messages in
                await self?.compactTranscript(sessionID: sessionID, used: used, messages: messages)
                    ?? messages
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

    public func send(_ text: String, sessionID: String,
                     attachments: [MessageAttachment] = []) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        guard !vm.running else {
            vm.note("The agent is still working; send again when it is done.")
            return
        }
        if attachments.isEmpty, let command = SlashCommand.parse(text) {
            runCommand(command, vm: vm)
            return
        }
        // "/deploy staging": a skill or command invoked by name.
        if attachments.isEmpty, let (skill, args) = matchSkillCommand(text, vm: vm),
           let expanded = invocationText(skill, arguments: args) {
            if isServerSwitching?() == true {
                vm.note("The Spark is switching models right now — send again once it says it's ready.")
                return
            }
            let display = "/\(skill.slug)" + (args.isEmpty ? "" : " \(args)")
            runTasks[sessionID] = Task { await runTurn(vm, text: display, modelText: expanded) }
            return
        }
        if isServerSwitching?() == true {
            vm.note("The Spark is switching models right now — send again once it says it's ready (usually a few minutes).")
            return
        }
        runTasks[sessionID] = Task { await runTurn(vm, text: text, attachments: attachments) }
    }

    // MARK: - Slash commands

    private func runCommand(_ command: SlashCommand, vm: SessionVM) {
        switch command {
        case .help:
            let lines = SlashCommand.catalog.map { "`\($0.usage)` — \($0.summary)" }
            vm.note("Commands:\n" + lines.joined(separator: "\n"))

        case .think(let arg):
            let fallback = config.activeProvider?.thinking
            guard let arg else {
                let current = vm.thinking ?? fallback
                vm.note("Thinking: **\(current?.label ?? "server default")**"
                        + (vm.thinking == nil ? " (from the provider setting)" : " (this chat)")
                        + ". Change it with `/think off|low|medium|high|max|default`.")
                return
            }
            if ["default", "reset", "auto"].contains(arg.lowercased()) {
                vm.thinking = nil
                vm.note("Thinking back to the provider default (\(fallback?.label ?? "server default")).")
            } else if let level = ThinkingLevel(userInput: arg) {
                vm.thinking = level
                vm.note("Thinking set to **\(level.label)** for this chat — \(level.blurb.lowercased()).")
            } else {
                vm.note("Unknown level “\(arg)”. Use off, low, medium, high, max, or default.", role: .error)
            }

        case .context:
            runTasks[vm.id] = Task {
                _ = await resolveRoute(force: true)
                let limit = contextLimit()
                let used = contextUsed(for: vm.id, draft: "")
                let source = contextSource()
                let model = config.activeProvider.map(effective)?.model ?? "?"
                vm.note("Context: \(used.formatted()) of \(limit.formatted()) tokens used "
                        + "(\(Int(Double(used) / Double(max(limit, 1)) * 100))%). Model `\(model)`; window \(source). "
                        + "Auto-compaction starts at \(Int(Compaction.triggerFraction * 100))%.")
                runTasks[vm.id] = nil
            }

        case .swap(let arg):
            if let onSwapCommand {
                onSwapCommand(arg, vm)
            } else {
                vm.note("Model switching isn't available.", role: .error)
            }

        case .skills:
            vm.note(skillsSummary(for: vm))

        case .skill(let arg):
            handleSkillCommand(arg, vm: vm)

        case .compact(let focus):
            runTasks[vm.id] = Task { await compactNow(vm, focus: focus) }

        case .goal(let goal):
            guard !goal.isEmpty else {
                vm.note("Usage: `/goal <what you want done>` — the agent keeps working, round after round, "
                        + "until it declares the goal complete (or needs you). Stop it any time with ⌘.")
                return
            }
            runTasks[vm.id] = Task { await runTurn(vm, text: goal, attachments: [], goal: goal) }
        }
    }

    /// `/compact`: fold the conversation into a summary now, whatever its size.
    private func compactNow(_ vm: SessionVM, focus: String?) async {
        let sessionID = vm.id
        vm.running = true
        vm.activity = "Compacting conversation…"
        defer {
            vm.running = false
            vm.activity = nil
            runTasks[sessionID] = nil
        }
        if transcripts[sessionID] == nil { hydrate(vm) }
        let messages = transcripts[sessionID] ?? []
        guard messages.contains(where: { $0.role == .user }) else {
            vm.note("Nothing to compact yet.")
            return
        }
        guard let profile = await resolveRoute() else {
            vm.note(LLMError.noModel.errorDescription ?? "No model configured.", role: .error)
            return
        }
        let prompt = systemPrompts[sessionID] ?? basePrompt
        let before = TokenEstimate.request(systemPrompt: prompt, messages: messages)
        guard let plan = Compaction.plan(usedTokens: before, limit: contextLimit(),
                                         transcript: messages, force: true) else {
            vm.note("The conversation is already as compact as it gets (~\(before.formatted()) tokens).")
            return
        }
        let client = OpenAIClient(profile: profile)
        guard let summary = await Compaction.summarize(client: client, plan: plan,
                                                       model: profile.model, focus: focus) else {
            vm.note("Compaction failed: the model did not return a summary. Nothing was changed.", role: .error)
            return
        }
        if Task.isCancelled { return }
        let newMessages = [LLMMessage(role: .system, content: Compaction.summaryHeader + summary)] + plan.toKeep
        applyCompaction(sessionID: sessionID, plan: plan, summary: summary, newMessages: newMessages)
        let after = TokenEstimate.request(systemPrompt: prompt, messages: newMessages)
        let text = "Compacted \(plan.toSummarize.count) messages: ~\(before.formatted()) → ~\(after.formatted()) tokens."
        vm.note(text)
        log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
    }

    // MARK: - Turns

    private func runTurn(_ vm: SessionVM, text: String, attachments: [MessageAttachment] = [],
                         goal: String? = nil, modelText: String? = nil) async {
        let sessionID = vm.id
        vm.running = true
        vm.stopping = false
        defer {
            vm.running = false
            vm.stopping = false
            vm.goal = nil
            vm.activity = nil
            vm.clearReasoning()
            vm.endStreaming()
            runTasks[sessionID] = nil
            log.touch(sessionID)
            vm.updatedAt = .now
            sessions.sort { $0.updatedAt > $1.updatedAt }
        }

        do {
            if let goal {
                try await runGoal(vm, goal: goal)
            } else {
                _ = try await turn(vm, modelText: modelText ?? text, displayText: text, attachments: attachments)
            }
        } catch is CancellationError {
            vm.endStreaming()
            let text = vm.goal != nil ? "Stopped. The goal was not finished." : "Stopped."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        } catch let error as LLMError {
            // A server overflow that still surfaced tells us the real window is
            // smaller than we budgeted — learn it so the gauge and future
            // compaction use the true number.
            if case .overflow(let limit, _) = error, limit > 0,
               let provider = config.activeProvider {
                probedContext[provider.routeID] = min(limit, probedContext[provider.routeID] ?? limit)
            }
            let message = Self.describe(error)
            vm.endStreaming()
            vm.note(message, role: .error)
            log.recordItem(sessionID, kind: "error", text: message, toolName: nil, argSummary: nil, output: nil, isError: true)
            banner = message
        } catch {
            let message = Self.describe(error)
            vm.endStreaming()
            vm.note(message, role: .error)
            log.recordItem(sessionID, kind: "error", text: message, toolName: nil, argSummary: nil, output: nil, isError: true)
            banner = message
        }
    }

    /// `/goal`: run turns until the model writes GOAL_COMPLETE (or GOAL_BLOCKED),
    /// re-stating the goal every round so it survives compaction.
    private func runGoal(_ vm: SessionVM, goal: String) async throws {
        let maxRounds = GoalProtocol.defaultMaxRounds
        vm.goal = .init(text: goal, round: 1, maxRounds: maxRounds)
        var result = try await turn(vm, modelText: GoalProtocol.kickoff(goal),
                                    displayText: "🎯 /goal \(goal)", attachments: [])
        var round = 1
        while true {
            switch GoalProtocol.status(of: result.finalText) {
            case .complete:
                let text = "✅ Goal complete after \(round) round\(round == 1 ? "" : "s")."
                vm.note(text)
                log.recordItem(vm.id, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
                return
            case .blocked(let why):
                let text = "⏸ Goal paused — the agent needs you: \(why)\nReply, then send `/goal \(goal.prefix(60))…` again to resume."
                vm.note(text)
                log.recordItem(vm.id, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
                return
            case .working:
                break
            }
            if Task.isCancelled { throw CancellationError() }
            guard round < maxRounds else {
                let text = "Goal stopped after \(maxRounds) rounds without being declared complete. Send `/goal` again to keep going."
                vm.note(text, role: .error)
                log.recordItem(vm.id, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
                return
            }
            round += 1
            vm.goal?.round = round
            result = try await turn(vm,
                                    modelText: GoalProtocol.continuation(goal, round: round, maxRounds: maxRounds,
                                                                         hitIterationLimit: result.hitIterationLimit),
                                    displayText: "↻ Goal round \(round): keep going", attachments: [])
        }
    }

    /// One user message → one engine run (which may take many tool steps).
    private func turn(_ vm: SessionVM, modelText: String, displayText: String,
                      attachments: [MessageAttachment]) async throws -> RunResult {
        let sessionID = vm.id
        vm.appendMessage(.user, displayText)
        log.recordItem(sessionID, kind: "user", text: displayText, toolName: nil, argSummary: nil, output: nil, isError: false)
        if vm.title == "New chat" {
            let first = displayText.split(separator: "\n").first.map(String.init) ?? displayText
            let title = String(first.prefix(48))
            if !title.isEmpty { renameSession(sessionID, to: title) }
        }
        if transcripts[sessionID] == nil { transcripts[sessionID] = [] }

        // Re-read what the server serves right now: the Spark can swap models
        // between turns, and the window/model id must follow.
        guard let profile = await resolveRoute() else { throw LLMError.noModel }
        let window = contextLimit()
        let thinking = vm.thinking
        let skillState = self.skillState(for: vm)
        let key = EngineKey(profile: profile, window: window, thinking: thinking, preset: vm.preset,
                            skills: skillState.signature, computerTools: config.computerToolsEnabled,
                            vision: visionOn(for: profile))
        if let previous = engineKeys[sessionID], previous.profile.model != profile.model {
            vm.note("The server is now serving `\(profile.model)` (was `\(previous.profile.model)`) — switched to it, \(window.formatted())-token window.")
        }
        let engine: Engine
        if let existing = engines[sessionID], engineKeys[sessionID] == key {
            engine = existing
        } else {
            engine = self.engine(for: sessionID, vm: vm, client: OpenAIClient(profile: profile),
                                 window: window, thinking: thinking, skillState: skillState)
            engineKeys[sessionID] = key
        }
        let input = transcripts[sessionID] ?? []

        // Engine events arrive on a pool thread; hop to main so the
        // timeline is only ever mutated from one place.
        let sink = self
        let result = try await engine.run(messages: input, userText: modelText,
                                          userAttachments: attachments) { event in
            Task { @MainActor in
                sink.apply(event, sessionID: sessionID)
            }
        }
        transcripts[sessionID] = result.messages
        vm.lastUsage = result.usage
        // How full the context is now: server-reported prompt tokens when
        // available, otherwise a character-based estimate of the whole
        // request (system prompt + transcript).
        let systemPrompt = engines[sessionID]?.systemPrompt ?? basePrompt
        vm.contextUsed = result.lastPromptTokens
            ?? Self.estimateTokens(systemPrompt: systemPrompt, messages: result.messages)
        if result.deniedCount > 0 {
            vm.note("\(result.deniedCount) tool call(s) were denied.")
        }
        if result.hitIterationLimit, vm.goal == nil {
            vm.note("Paused after \(engine.config.maxIterations) steps. Say “continue” to keep going, or use `/goal` for long tasks.")
        }
        return result
    }

    private func apply(_ event: EngineEvent, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        switch event {
        case .textDelta(let chunk):
            vm.clearReasoning()
            vm.appendDelta(chunk)

        case .reasoningDelta(let chunk):
            vm.appendReasoning(chunk)

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
            vm.clearReasoning()
            vm.startTool(id: id, name: name, preview: preview)

        case .toolFinished(let id, let name, let ok, let summary, let output):
            vm.finishTool(id: id, ok: ok, summary: summary, output: output)
            if name == "propose_skill", ok, output.contains("Saved draft") {
                refreshDrafts()
                vm.note("📝 The agent drafted a skill. It is not active until you approve it — open **Skills** under the composer (or Settings ▸ Skills) to review it.")
            }
            log.recordItem(sessionID, kind: "tool", text: summary, toolName: name,
                           argSummary: vm.entries.last(where: { $0.id == id })?.tool?.preview,
                           output: output, isError: !ok)

        case .toolImages(let id, let images):
            vm.attachImages(id: id, images.compactMap { ImageThumbnails.make(from: $0.data) ?? $0.data })

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

    // MARK: - Images

    /// Routes whose server rejected an image (learned at runtime).
    @ObservationIgnored private var noVisionRoutes: Set<String> = []

    fileprivate func visionOn(for profile: ProviderProfile?) -> Bool {
        guard let profile else { return true }
        if noVisionRoutes.contains(profile.routeID) { return false }
        return profile.vision ?? true
    }

    // MARK: - Skills

    /// Reload the approval queue (and tell open views to reload).
    public func refreshDrafts() {
        pendingDrafts = SkillDrafts.list(locations: skillLocations)
        skillsRevision += 1
    }

    /// Every skill visible from a chat's project (shadowed ones included).
    public func skills(for vm: SessionVM?) -> [Skill] {
        SkillCatalog.loadAll(project: vm?.workspaceURL ?? projectContext?.root,
                             locations: skillLocations, sources: config.skillSources)
    }

    public func selection(for sessionID: String) -> SkillSelection {
        let chosen = config.sessionSkills[sessionID]
        return SkillSelection(pinned: Set(chosen?.pinned ?? []), auto: chosen?.auto ?? true,
                              disabled: config.disabledSkills)
    }

    fileprivate func skillState(for vm: SessionVM) -> SkillState {
        let all = skills(for: vm)
        let selection = selection(for: vm.id)
        let result = SkillPrompt.build(skills: all, selection: selection)
        let active = SkillPrompt.active(all, selection)
        var hasher = Hasher()
        hasher.combine(result.text)
        hasher.combine(active.map(\.id))
        return SkillState(all: all, active: active, result: result, signature: hasher.finalize())
    }

    public func isPinned(_ skill: Skill, in vm: SessionVM) -> Bool {
        config.sessionSkills[vm.id]?.pinned.contains(skill.id) ?? false
    }

    public func setPinned(_ skill: Skill, _ on: Bool, in vm: SessionVM) {
        var chosen = config.sessionSkills[vm.id] ?? SessionSkillSelection()
        chosen.pinned.removeAll { $0 == skill.id }
        if on { chosen.pinned.append(skill.id) }
        config.sessionSkills[vm.id] = chosen
    }

    public func setAutoSkills(_ on: Bool, in vm: SessionVM) {
        var chosen = config.sessionSkills[vm.id] ?? SessionSkillSelection()
        chosen.auto = on
        config.sessionSkills[vm.id] = chosen
    }

    public func clearPinnedSkills(in vm: SessionVM) {
        var chosen = config.sessionSkills[vm.id] ?? SessionSkillSelection()
        chosen.pinned = []
        config.sessionSkills[vm.id] = chosen
    }

    /// `/skills`: what exists and what this chat uses.
    private func skillsSummary(for vm: SessionVM) -> String {
        let all = skills(for: vm).filter { !$0.shadowed }
        guard !all.isEmpty else {
            return "No skills yet. Create one in Settings ▸ Skills, import from Claude/Cursor, or try `/skill new <what it should do>`."
        }
        let sel = selection(for: vm.id)
        let lines = all.prefix(40).map { s -> String in
            let mark = sel.pinned.contains(s.id) ? "📌" : (sel.disabled.contains(s.id) ? "○ off" : "•")
            let tags = [s.origin.label, s.kind == .skill ? nil : s.kind.label.lowercased(), s.alwaysApply ? "always" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            return "\(mark) **\(s.name)** (\(tags)) — \(String(s.description.prefix(90)))"
        }
        var text = "Skills (\(all.count)):\n" + lines.joined(separator: "\n")
        if all.count > 40 { text += "\n… and \(all.count - 40) more (see the Skills button)." }
        text += "\n\nAuto-pick by the model: **\(sel.auto ? "on" : "off")**. `/skill <name>` selects one for this chat, `/<name>` runs it, `/skill new <what>` writes a new one."
        if !pendingDrafts.isEmpty { text += "\n📝 \(pendingDrafts.count) draft\(pendingDrafts.count == 1 ? "" : "s") awaiting your approval." }
        return text
    }

    private func handleSkillCommand(_ arg: String?, vm: SessionVM) {
        guard let arg, !arg.isEmpty else {
            vm.note(skillsSummary(for: vm))
            return
        }
        let lower = arg.lowercased()
        for verb in ["new ", "generate ", "create "] where lower.hasPrefix(verb) {
            let goal = String(arg.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            guard !goal.isEmpty else { break }
            runTasks[vm.id] = Task { await generateSkillFromChat(vm, goal: goal) }
            return
        }
        if ["off", "clear", "none"].contains(lower) {
            clearPinnedSkills(in: vm)
            vm.note("Cleared the skills selected for this chat.")
            return
        }
        if lower == "auto on" || lower == "auto off" {
            setAutoSkills(lower == "auto on", in: vm)
            vm.note("The model \(lower == "auto on" ? "can" : "can no longer") choose skills on its own in this chat.")
            return
        }
        let live = SkillPrompt.active(skills(for: vm), selection(for: vm.id))
        let key = SkillNaming.slug(arg)
        guard let skill = live.first(where: { $0.slug == key }) ?? live.first(where: { $0.slug.contains(key) && !key.isEmpty }) else {
            vm.note("No active skill matches “\(arg)”. `/skills` lists them.", role: .error)
            return
        }
        let now = !isPinned(skill, in: vm)
        setPinned(skill, now, in: vm)
        vm.note(now ? "📌 **\(skill.name)** is selected for this chat — its instructions are included from the next message."
                    : "**\(skill.name)** is no longer selected for this chat.")
    }

    /// `/name args`: the skill or command being run, if the text names one.
    private func matchSkillCommand(_ text: String, vm: SessionVM) -> (Skill, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let head = trimmed.prefix { !$0.isWhitespace }
        let word = String(head.dropFirst())
        guard !word.isEmpty else { return nil }
        let args = trimmed.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SkillNaming.slug(word)
        let live = SkillPrompt.active(skills(for: vm), selection(for: vm.id))
        guard let skill = live.first(where: { $0.userInvocable && ($0.slug == key || $0.name.lowercased() == word.lowercased()) })
        else { return nil }
        return (skill, args)
    }

    /// The message the model sees when the user runs a skill.
    private func invocationText(_ skill: Skill, arguments: String) -> String? {
        guard let doc = skill.document() else { return nil }
        var body = SkillArguments.expand(doc.body, arguments: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > SkillPrompt.perSkillCap { body = String(body.prefix(SkillPrompt.perSkillCap)) + "\n[… truncated]" }
        let withArgs = arguments.isEmpty ? "" : " with: \(arguments)"
        return """
        The user ran the skill “\(skill.name)”\(withArgs). Follow it now.

        <skill name="\(skill.name)" directory="\(skill.directory.path)">
        \(body)
        </skill>
        """
    }

    /// Ask the model to write a skill (optionally from a chat, or improving one).
    public func generateSkill(goal: String, from vm: SessionVM?, improving: String? = nil) async throws -> GeneratedSkill {
        guard let profile = await resolveRoute() else { throw LLMError.noModel }
        if let vm, transcripts[vm.id] == nil { hydrate(vm) }
        let conversation = vm.flatMap { transcripts[$0.id] } ?? []
        let request = SkillGenerationRequest(goal: goal, conversation: conversation,
                                             existingNames: skills(for: vm).map(\.name), improving: improving)
        return try await SkillGenerator.generate(client: OpenAIClient(profile: profile),
                                                 model: profile.model, request: request)
    }

    /// `/skill new …`: write a skill from this chat and queue it for approval.
    private func generateSkillFromChat(_ vm: SessionVM, goal: String) async {
        vm.running = true
        vm.activity = "Writing a skill…"
        defer { vm.running = false; vm.activity = nil; runTasks[vm.id] = nil }
        do {
            let generated = try await generateSkill(goal: goal, from: vm)
            if Task.isCancelled { return }
            let scope: SkillScope = vm.workspaceURL != nil ? .project : .user
            let draft = try SkillDrafts.create(text: generated.text, scope: scope, projectRoot: vm.workspaceURL,
                                               source: "chat", locations: skillLocations)
            refreshDrafts()
            let warn = generated.issues.filter { $0.severity >= .warning }.map(\.message)
            vm.note("📝 Drafted skill **\(draft.name)** — \(draft.description)\nIt is not active yet: open **Skills** under the composer to review, edit and approve it."
                    + (warn.isEmpty ? "" : "\nNotes: " + warn.joined(separator: " ")))
        } catch {
            vm.note("Couldn't write the skill: \(Self.describe(error))", role: .error)
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

    // MARK: - Context window

    /// The active model's context budget, in tokens.
    ///
    /// Precedence: a user-set override in the provider config wins, then a
    /// value learned by probing the server, then the well-known model tables,
    /// then a conservative default. Read-only — the view calls this; side
    /// effects (the probe) live in `ensureContextProbe`, called from the
    /// session lifecycle, so evaluating a SwiftUI body never fires a request.
    @MainActor
    public func contextLimit() -> Int {
        guard let provider = config.activeProvider else { return FallbackContextWindow.defaultLimit }
        if let override = provider.contextWindow, override > 0 { return override }
        if let probed = probedContext[provider.routeID] { return probed }
        let model = effective(provider).model
        return FallbackContextWindow.limit(for: model) ?? FallbackContextWindow.defaultLimit
    }

    /// Where the current window figure came from, for `/context` and the gauge tooltip.
    @MainActor
    public func contextSource() -> String {
        guard let provider = config.activeProvider else { return "default" }
        if let override = provider.contextWindow, override > 0 { return "set manually in Settings" }
        if probedContext[provider.routeID] != nil { return "detected from the server" }
        if FallbackContextWindow.limit(for: effective(provider).model) != nil { return "from the built-in model table (server did not report one)" }
        return "a conservative default (server did not report one — set it in Settings)"
    }

    /// The model id actually in use for the active route (follows a swap).
    @MainActor
    public var activeModelID: String? {
        config.activeProvider.map(effective)?.model
    }

    /// The profile with the model the server actually serves.
    @MainActor
    func effective(_ provider: ProviderProfile) -> ProviderProfile {
        var p = provider
        if let served = routeInfo[provider.routeID]?.servedModel, !served.isEmpty { p.model = served }
        return p
    }

    /// Ask the server what it serves and how big its window is, then return the
    /// profile to use. Cached for a few seconds so `/goal` rounds don't re-ask;
    /// a failed probe keeps whatever we knew.
    @MainActor
    @discardableResult
    func resolveRoute(force: Bool = false) async -> ProviderProfile? {
        guard let provider = config.activeProvider else { return nil }
        let routeID = provider.routeID
        let fresh = routeInfo[routeID].map { Date().timeIntervalSince($0.at) < 15 } ?? false
        if force || !fresh {
            if let info = await OpenAIClient(profile: provider).modelInfo(), !info.servedModels.isEmpty {
                routeInfo[routeID] = RouteInfo(servedModel: info.id, servedModels: info.servedModels,
                                               context: info.contextWindow, at: .now)
                if let limit = info.contextWindow, limit > 0, probedContext[routeID] != limit {
                    probedContext[routeID] = limit
                }
            }
        }
        return effective(provider)
    }

    /// Fire the server probe for the active route so `contextLimit` fills in a
    /// learned value. Safe to call repeatedly: one in flight at a time, and a
    /// recent answer is reused.
    @MainActor
    public func ensureContextProbe() {
        guard let provider = config.activeProvider else { return }
        let routeID = provider.routeID
        guard !probingContext.contains(routeID) else { return }
        if let info = routeInfo[routeID], Date().timeIntervalSince(info.at) < 60 { return }
        probingContext.insert(routeID)
        Task { [weak self] in
            await self?.resolveRoute(force: true)
            self?.probingContext.remove(routeID)
        }
    }

    /// Forget cached probes (Settings changed the route, or the user asked).
    @MainActor
    public func resetRouteCache() {
        routeInfo.removeAll()
        probedContext.removeAll()
        engines.removeAll()
        engineKeys.removeAll()
        ensureContextProbe()
    }

    /// How much of the context a session is using right now, in tokens.
    ///
    /// After any real turn this is the figure recorded at the end of that turn
    /// (server-reported prompt tokens when the model gives them, otherwise the
    /// character estimate of system prompt + transcript). The live draft adds
    /// on top, so the gauge tracks typing before the next send.
    @MainActor
    public func contextUsed(for sessionID: String, draft: String) -> Int {
        let recorded = sessions.first { $0.id == sessionID }?.contextUsed
        var used: Int
        if let recorded {
            used = recorded
        } else {
            // Fresh session: no turn has run, so estimate from the (empty)
            // transcript plus whatever the user is about to send. Use the
            // cached system prompt when the engine has been built; otherwise
            // the base prompt (project context is added at first turn).
            let prompt = systemPrompts[sessionID] ?? basePrompt
            used = Self.estimateTokens(systemPrompt: prompt,
                                       messages: transcripts[sessionID] ?? [])
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            used += max(1, trimmed.count / 4)
        }
        return used
    }

    /// Rough token count for a system prompt + message list.
    ///
    /// Character-based (≈ 4 chars/token) is the standard heuristic when the
    /// server won't report prompt tokens. It's a lower-ish bound for code and
    /// a good enough gauge for "how full is the context", which is all the UI
    /// needs — the exact figure arrives the moment a real turn runs.
    nonisolated static func estimateTokens(systemPrompt: String, messages: [LLMMessage]) -> Int {
        TokenEstimate.request(systemPrompt: systemPrompt, messages: messages)
    }

    // MARK: - Compaction
    //
    // When the model transcript grows toward the context window, the older
    // messages are replaced by a summary the model writes, and the recent tail
    // is kept verbatim. The engine calls this on every model call (in-loop), so
    // it also fires mid-run when tool output accumulates, and again on a server
    // overflow as a second line of defence.

    /// The engine's compaction hook: given the current request size and the full
    /// transcript, return a smaller transcript (older part summarized). No-op
    /// when under the trigger or when there's nothing old enough to fold.
    @MainActor
    public func compactTranscript(sessionID: String, used: Int, messages: [LLMMessage]) async -> [LLMMessage] {
        let limit = engineKeys[sessionID]?.window ?? contextLimit()
        guard let plan = Compaction.plan(usedTokens: used, limit: limit, transcript: messages) else {
            return messages
        }
        let vm = sessions.first { $0.id == sessionID }
        vm?.activity = "Compacting conversation to fit the context window…"
        defer { vm?.activity = nil }
        guard let summary = await summarize(sessionID: sessionID, plan: plan) else {
            // No summarizer available (no client, or it failed): keep the
            // transcript as-is; the server may still accept it, and an overflow
            // is surfaced rather than silently dropped.
            return messages
        }
        let newMessages = [LLMMessage(role: .system, content: Compaction.summaryHeader + summary)] + plan.toKeep
        applyCompaction(sessionID: sessionID, plan: plan, summary: summary, newMessages: newMessages)
        return newMessages
    }

    /// Ask the model for a continuity summary of the older part of the conversation.
    ///
    /// The summary request must fit comfortably inside the same window it is
    /// meant to protect — `Compaction.summarize` budgets it at ~40% of the
    /// limit so the input (clipped transcript) + the summary output stay well
    /// under the trigger.
    @MainActor
    private func summarize(sessionID: String, plan: Compaction.Plan) async -> String? {
        await resolveRoute()
        guard let profile = engineKeys[sessionID]?.profile ?? config.activeProvider.map(effective) else { return nil }
        return await Compaction.summarize(client: OpenAIClient(profile: profile), plan: plan, model: profile.model)
    }

    /// Rewrite the session's display + persisted log so the summarized part is
    /// replaced by a compaction divider, and point the model transcript at the
    /// new (shorter) list.
    @MainActor
    private func applyCompaction(sessionID: String, plan: Compaction.Plan,
                                 summary: String, newMessages: [LLMMessage]) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        transcripts[sessionID] = newMessages
        // Reset the gauge: the model now carries a small context.
        let prompt = systemPrompts[sessionID] ?? basePrompt
        vm.contextUsed = TokenEstimate.request(systemPrompt: prompt, messages: newMessages)

        // The transcript user-message count maps 1:1 onto the display user
        // entries, so the cut is "the Nth+1 user entry", where N is how many
        // user messages were summarized. Counting (instead of matching text)
        // keeps duplicates like repeated "hi" from cutting at the wrong spot.
        let summarizedUsers = plan.toSummarize.count(where: { $0.role == .user })
        let note = CompactionNote(removed: plan.toSummarize.count, summary: summary)
        var seenUsers = 0
        var cut: Int? = nil
        for (i, entry) in vm.entries.enumerated() {
            if case .message(let body) = entry.kind, body.role == .user {
                if seenUsers == summarizedUsers { cut = i; break }
                seenUsers += 1
            }
        }
        // Earlier messages stay visible above the divider (replay starts from
        // the divider, so they are not sent to the model again). A cut inside
        // one long turn has no later user entry: the divider goes at the end.
        let marker = ChatEntry(kind: .compaction(note))
        vm.entries.insert(marker, at: cut ?? vm.entries.count)
        // Re-sync the persisted log so a restart reloads the compacted conversation.
        log.resync(sessionID, rows: Self.logRows(for: vm.entries, sessionID: sessionID))
    }

    /// Rebuild persisted log rows from the current display entries. This is the
    /// single place that turns a (possibly compacted) session into storage.
    static func logRows(for entries: [ChatEntry], sessionID: String) -> [LogItemRow] {
        var out: [LogItemRow] = []
        var seq = 0
        for entry in entries {
            let (kind, text, toolName, argSummary, output, isError) = logRowFields(for: entry)
            out.append(LogItemRow(sessionID: sessionID, seq: seq, kind: kind, text: text,
                                  toolName: toolName, argSummary: argSummary, output: output,
                                  isError: isError, at: entry.at))
            seq += 1
        }
        return out
    }

    /// Map one display entry to its persisted-row fields.
    private static func logRowFields(for entry: ChatEntry)
        -> (kind: String, text: String?, toolName: String?, argSummary: String?, output: String?, isError: Bool) {
        switch entry.kind {
        case .message(let body):
            switch body.role {
            case .user: return ("user", body.text, nil, nil, nil, false)
            case .assistant: return ("assistant", body.text, nil, nil, nil, false)
            case .notice: return ("notice", body.text, nil, nil, nil, false)
            case .error: return ("error", body.text, nil, nil, nil, true)
            }
        case .tool(let a):
            return ("tool", a.summary, a.name, a.preview, a.output, a.isOk == false)
        case .todos:
            return ("todos", nil, nil, nil, nil, false)
        case .compaction(let note):
            // The removed count rides in argSummary so a reloaded divider still
            // says how much was folded away.
            return ("compaction", note.summary, "compaction", String(note.removed), nil, false)
        }
    }

    public static func describe(_ error: Error) -> String {
        if let llm = error as? LLMError {
            return llm.errorDescription ?? "\(llm)"
        }
        return error.localizedDescription
    }
}