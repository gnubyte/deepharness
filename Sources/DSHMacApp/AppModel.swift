import Foundation
import Observation
import AppKit
import DSHKit

/// One conversation in the sidebar.
@MainActor
@Observable
final class SessionVM: Identifiable {
    let id: String
    var title: String
    var running = false
    var blank: Bool
    var cwd: String?
    var updatedAt: Date
    var transcript = TranscriptAssembler()
    /// Model route currently selected for this session.
    var provider: String?
    var model: String?
    /// True once history has been fetched, so switching sessions doesn't refetch.
    var hydrated = false

    /// Blocked-on interactions. Both are answerable server-requests, so each
    /// carries the rpcId its answer must echo.
    var approvals: [PendingApproval] = []
    var questions: [PendingQuestions] = []
    /// Complete inbox snapshot; the host replaces it wholesale on every change.
    var queue: [QueuedItem] = []
    /// Direct children, loaded on demand.
    var subagents: [SubagentEntry] = []
    var subagentsLoaded = false

    /// Generic per-session projection store, higher-seq-wins.
    ///
    /// Titles, stats, goals, and token usage all ride this one pair — a
    /// history-tail `projections` block seeds it and `session/projection`
    /// frames update it. There is no `title` field on a session summary.
    var projections: [String: JSONValue] = [:]
    private var projectionSeq: [String: Int] = [:]

    func applyProjection(key: String, value: JSONValue, seq: Int) {
        guard seq >= (projectionSeq[key] ?? Int.min) else { return }
        projectionSeq[key] = seq
        projections[key] = value
    }

    /// Seed from a `projections` block (`{asOfSeq, values}`).
    func seedProjections(_ block: JSONValue?) {
        guard let block else { return }
        let seq = block["asOfSeq"]?.intValue ?? 0
        for (key, value) in block["values"]?.objectValue ?? [:] {
            applyProjection(key: key, value: value, seq: seq)
        }
    }

    var projectedTitle: String? {
        guard let t = projections["title"]?.stringValue, !t.isEmpty else { return nil }
        return t
    }

    // Telemetry is computed host-side and pushed; the client only projects it.
    var contextPressure: ContextPressure? { ContextPressure(projections["contextPressure"]) }
    var contextBreakdown: ContextBreakdown? { ContextBreakdown(projections["contextBreakdown"]) }
    var tokenUsage: TokenUsage? { TokenUsage(projections["tokenUsage"]) }
    var sessionStats: SessionStats? { SessionStats(projections["sessionStats"]) }
    var permissions: PermissionState? { PermissionState(projections["permissions"]) }

    var queuedItems: [QueuedItem] { queue.filter { $0.placement == .queued } }
    var steeringItems: [QueuedItem] { queue.filter { $0.placement == .steering } }
    /// Anything demanding an answer before the turn can continue.
    var isBlocked: Bool { !approvals.isEmpty || !questions.isEmpty }

    init(id: String, title: String? = nil, blank: Bool = true, cwd: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.title = title ?? "New chat"
        self.blank = blank
        self.cwd = cwd
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        if let t = projectedTitle { return t }
        if let t = transcript.title, !t.isEmpty { return t }
        if title != "New chat", !title.isEmpty { return title }
        // Fall back to the first thing the person actually typed.
        if let first = transcript.items.first(where: { if case .user = $0.kind { return true } else { return false } }) {
            let line = first.text.split(separator: "\n").first.map(String.init) ?? first.text
            if !line.isEmpty { return String(line.prefix(60)) }
        }
        return "New chat"
    }

    var subtitle: String {
        if running { return "Running…" }
        if let cwd, let name = cwd.split(separator: "/").last { return String(name) }
        return updatedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// One configurable provider route.
struct ProviderVM: Identifiable, Hashable {
    let id: String
    let displayName: String
    let settingsNs: String
    let active: Bool
    /// True when the adapter ships nothing under this key — a hand-declared
    /// route such as a vLLM or Ollama endpoint.
    let declared: Bool
}

struct ModelVM: Identifiable, Hashable {
    /// Composite key for SwiftUI identity only.
    let id: String
    /// The provider-owned model id exactly as the route serves it. Kept
    /// verbatim because model ids legitimately contain slashes (`openrouter`
    /// serves `anthropic/claude-…`), so it cannot be recovered by trimming a
    /// prefix off `id`.
    let modelId: String
    let name: String
    let provider: String
    let providerName: String

    init(modelId: String, name: String, provider: String, providerName: String) {
        self.id = "\(provider)\u{0}\(modelId)"
        self.modelId = modelId
        self.name = name
        self.provider = provider
        self.providerName = providerName
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: - Connection

    var baseURL = AppModel.defaultURL
    private(set) var api: APIClient
    private var muxTask: Task<Void, Never>?
    private var hostTask: Task<Void, Never>?
    private var muxStream: EventStream?
    private var hostStream: EventStream?

    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(version: String, cwd: String)
        case failed(String)
    }
    var connection: Connection = .disconnected

    // MARK: - Content

    var sessions: [SessionVM] = []
    var selectedID: String?
    var providers: [ProviderVM] = []
    var models: [ModelVM] = []
    var banner: String?

    var workspaces: [Workspace] = []
    var archivedSessionIds: Set<String> = []
    var searchQuery = ""
    var searchHits: [SearchHit] = []
    var searchHasMore = false
    /// Set when search itself failed, so the sidebar can say why instead of
    /// showing an empty result that looks like "nothing matched".
    var searchError: String?
    private var searchTask: Task<Void, Never>?

    /// The harness child process, when this app started one itself.
    let harness = HarnessProcess()

    /// Local record of everything the user has typed, independent of the
    /// harness's own session logs.
    private(set) var promptStore: PromptStore?
    private(set) var promptStoreError: String?

    var selected: SessionVM? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    /// The default loopback endpoint `dsh web` serves.
    static let defaultURL = URL(string: "http://127.0.0.1:3099")!

    init() {
        // @Observable rewrites stored properties, so init must not read one
        // back through `self` before every property is initialized.
        api = APIClient(baseURL: Self.defaultURL)
        do {
            promptStore = try PromptStore()
        } catch {
            // History is a convenience, not a precondition for chatting.
            promptStoreError = Self.describe(error)
        }
    }

    // MARK: - Lifecycle

    func connect() async {
        connection = .connecting
        api = APIClient(baseURL: baseURL)
        do {
            let host = try await api.hostDescribe()
            connection = .connected(
                version: host["version"]?.stringValue ?? "?",
                cwd: host["cwd"]?.stringValue ?? "?"
            )
            await refreshSessions()
            await refreshProviders()
            await refreshWorkspaces()
            await refreshDefaultPreset()
            startStreams()
        } catch {
            connection = .failed(Self.describe(error))
        }
    }

    func disconnect() {
        muxTask?.cancel(); muxTask = nil
        hostTask?.cancel(); hostTask = nil
        let (mux, host) = (muxStream, hostStream)
        muxStream = nil; hostStream = nil
        Task { await mux?.stop(); await host?.stop() }
        connection = .disconnected
    }

    /// Start the bundled harness, then connect to it.
    func startHarnessAndConnect(repoPath: String, port: Int) async {
        connection = .connecting
        do {
            let url = try await harness.start(repoPath: repoPath, port: port)
            baseURL = url
            await connect()
        } catch {
            connection = .failed(Self.describe(error))
        }
    }

    // MARK: - Streams

    private func startStreams() {
        muxTask?.cancel()
        hostTask?.cancel()

        let mux = EventStream(baseURL: baseURL, kind: .mux)
        muxStream = mux
        muxTask = Task { [weak self] in
            for await signal in await mux.signals() {
                guard let self else { return }
                switch signal {
                case .frame(let frame): await self.handleMux(frame)
                // `since` is unimplemented upstream, so recovery is documented
                // as reopen + refetch rather than a resumed cursor.
                case .reconnected: await self.rebaseline()
                case .closed(let err):
                    if let err { await self.note("Event stream closed: \(Self.describe(err))") }
                }
            }
        }

        let hostStreamLocal = EventStream(baseURL: baseURL, kind: .host)
        hostStream = hostStreamLocal
        hostTask = Task { [weak self] in
            for await signal in await hostStreamLocal.signals() {
                guard let self else { return }
                if case .frame(let frame) = signal { await self.handleHost(frame) }
            }
        }
    }

    private func handleMux(_ frame: Frame) {
        guard let sessionId = frame.sessionId else { return }
        switch frame.type {
        case "session/event":
            guard let event = frame.event else { return }
            let vm = ensure(sessionId)
            vm.transcript.apply(event: event, view: frame.view)
            vm.running = vm.transcript.running
            if vm.transcript.items.contains(where: { if case .user = $0.kind { return true } else { return false } }) {
                vm.blank = false
            }
            if event["type"]?.stringValue == "request/header",
               let cfg = event.path("data", "header", "config") {
                vm.provider = cfg["provider"]?.stringValue ?? vm.provider
                vm.model = cfg["model"]?.stringValue ?? vm.model
            }
            vm.updatedAt = .now
        case "session/subscribed":
            _ = ensure(sessionId)

        case "approval/requested":
            guard let approval = PendingApproval(frame: frame) else { return }
            let vm = ensure(sessionId)
            // The stream replays still-pending requests on reconnect with the
            // same rpcId, so replace rather than append a duplicate.
            vm.approvals.removeAll { $0.approvalId == approval.approvalId }
            vm.approvals.append(approval)

        case "approval/resolved":
            guard let id = frame.payload["approvalId"]?.stringValue else { return }
            ensure(sessionId).approvals.removeAll { $0.approvalId == id }

        case "question/requested":
            guard let questions = PendingQuestions(frame: frame) else { return }
            let vm = ensure(sessionId)
            vm.questions.removeAll { $0.rpcId == questions.rpcId }
            vm.questions.append(questions)

        case "question/resolved":
            guard let raw = frame.payload["questionRpcId"]?.stringValue else { return }
            ensure(sessionId).questions.removeAll { $0.rpcId.raw == raw }

        case "session/queue":
            // The whole snapshot is authoritative — replace, never merge.
            let items = frame.payload["items"]?.arrayValue ?? []
            ensure(sessionId).queue = items.compactMap(QueuedItem.init)

        case "session/projection":
            guard let key = frame.payload["key"]?.stringValue,
                  let value = frame.payload["value"] else { return }
            ensure(sessionId).applyProjection(
                key: key,
                value: value,
                seq: frame.payload["seq"]?.intValue ?? 0
            )

        default:
            break
        }
    }

    private func handleHost(_ frame: Frame) {
        switch frame.type {
        case "host/session-added":
            let vm = ensure(frame.sessionId ?? "")
            vm.blank = frame.payload["blank"]?.boolValue ?? vm.blank
            vm.cwd = frame.payload["cwd"]?.stringValue ?? vm.cwd
        case "host/session-removed":
            if let id = frame.sessionId { sessions.removeAll { $0.id == id } }
            if selectedID != nil, !sessions.contains(where: { $0.id == selectedID }) {
                selectedID = sessions.first?.id
            }
        case "host/session-status":
            if let id = frame.sessionId, let vm = sessions.first(where: { $0.id == id }) {
                vm.running = frame.payload["running"]?.boolValue ?? false
                // A blank session never runs, so the first run clears the bit.
                if vm.running { vm.blank = false }
            }
        case "host/agent-error":
            let message = frame.payload["message"]?.stringValue ?? "The agent reported an error."
            // Land it in the owning conversation rather than a modal; the
            // frame carries a sessionId precisely so it can be placed.
            if let id = frame.sessionId, let vm = sessions.first(where: { $0.id == id }) {
                vm.transcript.pushNotice(message)
            } else {
                note(message)
            }

        // Workspace frames all push complete snapshots, so upsert or replace
        // rather than trying to reconcile increments.
        case "host/workspace-changed":
            guard let ws = frame.payload["workspace"].flatMap(Workspace.init) else { return }
            if let i = workspaces.firstIndex(where: { $0.id == ws.id }) { workspaces[i] = ws }
            else { workspaces.append(ws) }

        case "host/workspace-removed":
            guard let id = frame.payload["workspaceId"]?.stringValue else { return }
            workspaces.removeAll { $0.id == id }

        case "host/workspace-order-changed":
            let order = (frame.payload["workspaceIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            workspaces.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }

        case "host/archived-sessions-changed":
            let ids = (frame.payload["archivedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
            archivedSessionIds = Set(ids)

        default:
            break
        }
    }

    private func rebaseline() {
        Task {
            await refreshSessions()
            if let vm = selected { await hydrate(vm, force: true) }
        }
    }

    // MARK: - Data

    func refreshSessions() async {
        guard let items = try? await api.sessionList() else { return }
        for item in items {
            guard let id = item["sessionId"]?.stringValue else { continue }
            let vm = ensure(id)
            vm.running = item["running"]?.boolValue ?? false
            vm.blank = item["blank"]?.boolValue ?? vm.blank
            vm.cwd = item["cwd"]?.stringValue ?? vm.cwd
            // The list summary carries no title — it rides the projections block.
            vm.seedProjections(item["projections"])
            if let ms = item["updatedAt"]?.doubleValue {
                vm.updatedAt = Date(timeIntervalSince1970: ms / 1000)
            }
        }
        // Hide blank sessions the way the contract prescribes, but never hide
        // the one the user is looking at.
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if selectedID == nil { selectedID = visibleSessions.first?.id }
    }

    var visibleSessions: [SessionVM] {
        sessions.filter { !$0.blank || $0.id == selectedID || !$0.transcript.items.isEmpty }
    }

    func refreshProviders() async {
        if let list = try? await api.providers() {
            providers = list.compactMap { p in
                guard let id = p["provider"]?.stringValue else { return nil }
                return ProviderVM(
                    id: id,
                    displayName: p["displayName"]?.stringValue ?? id,
                    settingsNs: p["settingsNs"]?.stringValue ?? "",
                    active: p["active"]?.boolValue ?? false,
                    declared: p["declared"]?.boolValue ?? false
                )
            }
        }
        if let catalog = try? await api.models() {
            let names = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.displayName) })
            models = (catalog["groups"]?.arrayValue ?? []).flatMap { group -> [ModelVM] in
                let pid = group["id"]?.stringValue ?? ""
                let pname = group["name"]?.stringValue ?? names[pid] ?? pid
                return (group["models"]?.arrayValue ?? []).compactMap { m in
                    guard let mid = m["id"]?.stringValue else { return nil }
                    return ModelVM(
                        modelId: mid,
                        name: m["name"]?.stringValue ?? mid,
                        provider: pid,
                        providerName: pname
                    )
                }
            }
        }
    }

    /// Fetch a session's durable history once, so switching chats shows the past.
    func hydrate(_ vm: SessionVM, force: Bool = false) async {
        guard force || !vm.hydrated else { return }
        // Mark only on success: a failed fetch that set the flag first would
        // strand the session showing an empty transcript with no way back.
        guard let history = try? await api.sessionHistory(vm.id) else { return }
        vm.hydrated = true
        var fresh = TranscriptAssembler()
        for entry in history["events"]?.arrayValue ?? [] {
            // History wraps each event as `{event: …}`; the mux stream does not.
            fresh.applyHistoryEntry(entry)
        }
        // Only replace when history actually carried something; a live turn in
        // progress must not be wiped by an empty reply.
        if !fresh.items.isEmpty { vm.transcript = fresh }
        vm.seedProjections(history["projections"])
        if let sel = history.path("selection", "current") ?? history["selection"] {
            vm.provider = sel["provider"]?.stringValue ?? vm.provider
            vm.model = sel["model"]?.stringValue ?? vm.model
        }
    }

    // MARK: - Actions

    @discardableResult
    func newSession(workspaceId: String? = nil, cwd: String? = nil) async -> String? {
        do {
            let id = try await api.sessionCreate(workspaceId: workspaceId, cwd: cwd)
            let vm = ensure(id)
            // A workspace resolves its own canonical path host-side, so take
            // that rather than guessing; refreshWorkspaces fills it in.
            vm.cwd = cwd ?? workspaces.first { $0.id == workspaceId }?.path
            vm.hydrated = true
            selectedID = id
            if workspaceId != nil { await refreshWorkspaces() }
            return id
        } catch {
            note(Self.describe(error))
            return nil
        }
    }

    // MARK: - Projects

    /// The project the selected chat belongs to, if any.
    var activeProject: Workspace? {
        guard let id = selectedID else { return nil }
        return workspaces.first { $0.sessionIds.contains(id) }
    }

    /// Adopt a folder as a coding project and open a chat in it.
    ///
    /// The harness never creates the directory — `workspace.create` adopts an
    /// existing one and idempotently returns the same workspace if the folder
    /// is already a project, so re-opening a folder reuses it instead of
    /// duplicating.
    @discardableResult
    func openProject(path: String) async -> Workspace? {
        do {
            let value = try await api.workspaceCreate(path: path)
            await refreshWorkspaces()
            guard let ws = value["workspace"].flatMap(Workspace.init) else { return nil }

            // Re-opening an existing project should land the user in it rather
            // than pile up empty chats.
            let existing = sessions(in: ws).filter { !$0.blank || !$0.transcript.items.isEmpty }
            if let latest = existing.max(by: { $0.updatedAt < $1.updatedAt }) {
                selectedID = latest.id
                await hydrate(latest)
            } else {
                await newSession(workspaceId: ws.id)
            }
            return ws
        } catch {
            note(Self.describe(error))
            return nil
        }
    }

    /// `steer` only means anything while a turn is running; an idle session
    /// takes the message immediately either way.
    func send(_ text: String, attachments: [Attachment], steer: Bool = false) async {
        guard let vm = selected else { return }
        let mode = (steer && vm.running) ? "steer" : "queue"
        do {
            try await api.prompt(vm.id, text: text, attachments: attachments, mode: mode)
            vm.blank = false
            await recordPrompt(vm, text: text, attachmentCount: attachments.count, mode: mode)
        } catch {
            note(Self.describe(error))
        }
    }

    /// Record a sent prompt locally. Never fails the send.
    private func recordPrompt(_ vm: SessionVM, text: String, attachmentCount: Int, mode: String) async {
        guard let store = promptStore, !text.isEmpty else { return }
        do {
            try await store.record(
                sessionId: vm.id,
                sessionTitle: vm.projectedTitle,
                cwd: vm.cwd,
                text: text,
                attachmentCount: attachmentCount,
                mode: mode
            )
        } catch {
            promptStoreError = Self.describe(error)
        }
    }

    // MARK: - Files

    /// Open a produced file through the host, which is the process that can
    /// actually see the path.
    func openPath(_ path: String) async {
        do {
            try await api.openPath(path)
        } catch {
            note(Self.describe(error))
        }
    }

    /// Reveal in the local Finder. Only meaningful for a loopback host, which
    /// is the shape this app is built for.
    func revealLocally(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }

    // MARK: - Permissions

    /// The preset newly created chats will run under.
    var defaultPreset: String = "workspace-write"

    func refreshDefaultPreset() async {
        guard let value = try? await api.call("settings.describe", .object([:])) else { return }
        for ns in value["namespaces"]?.arrayValue ?? [] where ns["ns"]?.stringValue == "permission" {
            defaultPreset = ns.path("value", "defaultPreset")?.stringValue ?? defaultPreset
        }
    }

    /// Set the preset newly created chats start under.
    ///
    /// A session pins its preset at creation, so this cannot change a chat that
    /// already exists — the harness's own `/permissionPresets` command is the
    /// only live switch and this deployment does not dispatch slash commands
    /// (a `/nonsense` prompt is accepted as plain text rather than rejected as
    /// `unknown-command`). `startChat` therefore creates a fresh session so the
    /// grant actually takes effect somewhere the user can use it.
    func setDefaultPreset(_ preset: String, startChat: Bool) async {
        do {
            _ = try await api.settingsUpdate(ns: "permission", patch: ["defaultPreset": .string(preset)])
            defaultPreset = preset
            if startChat {
                let workspaceId = activeProject?.id
                await newSession(workspaceId: workspaceId)
            }
        } catch {
            note(Self.describe(error))
        }
    }

    func cancel() async {
        guard let vm = selected, vm.running else { return }
        try? await api.cancel(vm.id)
    }

    func selectModel(_ model: ModelVM) async {
        guard let vm = selected else { return }
        do {
            try await api.selectModel(vm.id, provider: model.provider, model: model.modelId)
            vm.provider = model.provider
            vm.model = model.modelId
        } catch {
            note(Self.describe(error))
        }
    }

    func rename(_ vm: SessionVM, to title: String) async {
        do {
            try await api.rename(vm.id, title: title)
            vm.title = title
        } catch {
            note(Self.describe(error))
        }
    }

    // MARK: - Answering the agent

    func answer(_ approval: PendingApproval, allow: Bool) async {
        // Drop it locally first: the resolved frame confirms, but the button
        // should not stay live while the round trip is in flight.
        selected?.approvals.removeAll { $0.approvalId == approval.approvalId }
        do {
            try await api.answerApproval(
                rpcId: approval.rpcId,
                sessionId: approval.sessionId,
                approvalId: approval.approvalId,
                allow: allow
            )
        } catch {
            note(Self.describe(error))
        }
    }

    func answer(_ pending: PendingQuestions, answers: [(id: String, selected: [String], custom: String?)]) async {
        selected?.questions.removeAll { $0.rpcId == pending.rpcId }
        do {
            try await api.answerQuestions(rpcId: pending.rpcId, sessionId: pending.sessionId, answers: answers)
        } catch {
            note(Self.describe(error))
        }
    }

    // MARK: - Queue

    func removeQueued(_ item: QueuedItem) async {
        guard let vm = selected else { return }
        do { try await api.removeQueued(vm.id, itemId: item.id) } catch { note(Self.describe(error)) }
    }

    func steerQueued(_ item: QueuedItem) async {
        guard let vm = selected else { return }
        do { try await api.steerQueued(vm.id, itemId: item.id) } catch { note(Self.describe(error)) }
    }

    func editQueued(_ item: QueuedItem, text: String) async {
        guard let vm = selected else { return }
        do { try await api.editQueued(vm.id, itemId: item.id, text: text) } catch { note(Self.describe(error)) }
    }

    // MARK: - Search

    /// Debounced so typing doesn't fire a request per keystroke.
    func runSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            searchHasMore = false
            searchError = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            do {
                let (items, hasMore) = try await api.search(trimmed)
                guard !Task.isCancelled else { return }
                searchHits = items.compactMap(SearchHit.init)
                searchHasMore = hasMore
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchHits = []
                searchHasMore = false
                let message = Self.describe(error)
                // A deployment can ship the index switched off; say so rather
                // than reporting a false "no matches".
                searchError = message.contains("search is disabled")
                    ? "Search is turned off in this harness (session-query openAt: never)."
                    : message
            }
        }
    }

    // MARK: - Fork

    /// Fork at a transcript position, or at the tail when `atSeq` is nil.
    func fork(_ vm: SessionVM, atSeq: Int? = nil) async {
        do {
            let value = try await api.fork(vm.id, atSeq: atSeq)
            guard let id = value["sessionId"]?.stringValue else { return }
            let child = ensure(id)
            child.cwd = vm.cwd
            child.blank = false
            await refreshSessions()
            selectedID = id
            await hydrate(child, force: true)
        } catch {
            note(Self.describe(error))
        }
    }

    // MARK: - Workspaces

    func refreshWorkspaces() async {
        guard let (items, archived) = try? await api.workspaceList() else { return }
        workspaces = items.compactMap(Workspace.init)
        archivedSessionIds = Set(archived)
    }

    func createWorkspace(path: String) async {
        do {
            _ = try await api.workspaceCreate(path: path)
            await refreshWorkspaces()
        } catch {
            note(Self.describe(error))
        }
    }

    func renameWorkspace(_ ws: Workspace, title: String) async {
        do {
            try await api.workspaceRename(ws.id, title: title)
            await refreshWorkspaces()
        } catch {
            note(Self.describe(error))
        }
    }

    /// Removes the registration only — no directory or log is deleted.
    func deleteWorkspace(_ ws: Workspace) async {
        do {
            try await api.workspaceDelete(ws.id)
            await refreshWorkspaces()
        } catch {
            note(Self.describe(error))
        }
    }

    func setArchived(_ session: SessionVM, archived: Bool) async {
        guard let ws = workspaces.first(where: { $0.sessionIds.contains(session.id) }) else {
            note("That chat isn’t in a workspace, so it can’t be archived.")
            return
        }
        do {
            try await api.archiveSession(ws.id, sessionId: session.id, archived: archived)
            await refreshWorkspaces()
        } catch {
            note(Self.describe(error))
        }
    }

    /// Sessions not accounted by any workspace.
    var ungroupedSessions: [SessionVM] {
        let grouped = Set(workspaces.flatMap(\.sessionIds))
        return visibleSessions.filter { !grouped.contains($0.id) }
    }

    func sessions(in workspace: Workspace) -> [SessionVM] {
        // Workspace order is manually owned, so follow it rather than re-sorting.
        workspace.sessionIds.compactMap { id in
            visibleSessions.first { $0.id == id }
        }
    }

    // MARK: - Subagents

    func loadSubagents(_ vm: SessionVM, force: Bool = false) async {
        guard force || !vm.subagentsLoaded else { return }
        vm.subagentsLoaded = true
        guard let catalog = try? await api.subagentList(parent: vm.id) else { return }
        vm.subagents = (catalog["entries"]?.arrayValue ?? []).compactMap(SubagentEntry.init)
    }

    func subagentTranscript(parent: SessionVM, child: SubagentEntry) async -> TranscriptAssembler {
        var assembler = TranscriptAssembler()
        let mode: String = child.isContinuable ? "continuable" : "one-shot"
        guard let history = try? await api.subagentHistory(parent: parent.id, child: child.id, mode: mode) else {
            return assembler
        }
        for entry in history["events"]?.arrayValue ?? [] {
            assembler.applyHistoryEntry(entry)
        }
        return assembler
    }

    func promptSubagent(parent: SessionVM, child: SubagentEntry, text: String) async {
        do {
            _ = try await api.subagentPrompt(parent: parent.id, child: child.id, text: text)
        } catch {
            note(Self.describe(error))
        }
    }

    func interruptSubagent(parent: SessionVM, child: SubagentEntry) async {
        do {
            try await api.subagentInterrupt(
                parent: parent.id,
                child: child.id,
                mode: child.isContinuable ? "continuable" : "one-shot"
            )
        } catch {
            note(Self.describe(error))
        }
    }

    // MARK: - Helpers

    private func ensure(_ id: String) -> SessionVM {
        if let existing = sessions.first(where: { $0.id == id }) { return existing }
        let vm = SessionVM(id: id)
        sessions.append(vm)
        return vm
    }

    func note(_ message: String) {
        banner = message
    }

    static func describe(_ error: Error) -> String {
        if let rpc = error as? RpcError { return rpc.message }
        if let t = error as? TransportError { return t.errorDescription ?? "\(t)" }
        return error.localizedDescription
    }
}
