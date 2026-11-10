import SwiftUI
import Observation
import VisionHarnessCore

/// Which half of the app the window is showing.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case chat, code, agent, automations
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "Chat"
        case .code: "Code"
        case .agent: "Agent"
        case .automations: "Automations"
        }
    }
    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .agent: "brain.head.profile"
        case .automations: "clock.badge.checkmark"
        }
    }
}

enum SettingsTab: Hashable { case general, models, spark, guardian, skills, computer, plugins, editor, automations }
enum SkillsAction: Equatable { case generate, importSkills, newManual }

/// A pending "new chat in a worktree", waiting for its name.
struct WorktreeRequest: Identifiable {
    let id = UUID()
    let project: URL
}

/// A `ProviderProfile?` that the API server's network thread can read while
/// the main actor updates it.
final class ProfileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProviderProfile?
    func set(_ newValue: ProviderProfile?) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> ProviderProfile? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Root-level state: the config, the transport that drives sessions, the
/// current project folder, and the code-mode workspace.
@MainActor
@Observable
final class AppModel {
    let config = AppConfig.shared
    let transport: AppTransport
    /// The DGX Spark's model switcher.
    let spark: SparkController
    /// File tree, open editors, and terminals for the current project.
    let code = CodeWorkspace()

    var mode: WorkspaceMode = .chat {
        didSet {
            config.lastMode = mode.rawValue
            modeChanged(from: oldValue)
        }
    }
    /// Where each side left off, so moving between Agent mode and the chats
    /// comes back to the same conversation.
    @ObservationIgnored private var lastChatID: String?
    @ObservationIgnored private var lastAgentID: String?
    /// Showing the browsable archive of old chats.
    var showArchive = false
    /// Asking for the name of a new worktree chat, in this project.
    var worktreeRequest: WorktreeRequest?
    /// Finishing this worktree chat: merge, clean up, archive.
    var finishingWorktree: SessionVM?
    /// Who this Guardian account may talk to. Here rather than on the service, so views follow it.
    private(set) var guardianPeople: [GuardianPerson] = []
    @ObservationIgnored private var lastGuardianRefresh = Date.distantPast
    /// Sending this chat to someone in Guardian.
    var sendingToGuardian: SessionVM?
    /// Presented over everything on first run, and on demand afterwards.
    var showWizard = false
    var showSettings = false
    var showMemoryAndSkills = false
    /// The task-queue side panel.
    var showQueuePanel = false
    /// The credential vault window.
    var showVault = false
    /// The durable prompt-history viewer (all modes).
    var showPromptHistory = false
    /// The Amazon Bedrock guide, when it is open (nil = closed).
    var bedrockGuide: BedrockGuideRequest?
    /// The "Connect my Spark Swapper" guide, when it is open.
    var swapperGuide: SwapperGuideRequest?
    /// The "Connect a subscription plan" guide, when it is open.
    var planGuide: PlanGuideRequest?
    /// Which Settings tab is showing; set before `showSettings` to deep-link.
    var settingsTab: SettingsTab = .general
    /// A skills action a caller wants the Skills tab to start with.
    var skillsAction: SkillsAction?
    /// Text a caller wants dropped into the selected chat's composer (the
    /// prompt timeline's "Reuse in composer"). ChatView picks it up in
    /// `onChange`, like `code.pendingMention`.
    var pendingComposerText: String?
    /// The Guardian connection: sign-in state, prompt sync, skills, chats.
    let guardian = GuardianService(appSupport: AppPaths.support)
    /// The folder both modes operate in, plus any additional folders the
    /// agent also works across (multi-folder sessions).
    private(set) var project: URL?
    private(set) var additionalProjects: [URL] = []
    /// The one-time "DSH is now Vision" notice, until the user dismisses it.
    private(set) var renameNotice: String?
    /// Scheduled automations: the pure engine, its persisted store, and the
    /// app-side tick that turns due schedules into runs.
    let automations = AutomationScheduler()
    private var automationFile: URL {
        AppPaths.support.appendingPathComponent("automations.json")
    }
    private var automationTick: Task<Void, Never>?
    /// The local API server exposing the default model (nil = not running).
    private var apiServer: LocalAPIServer?
    /// Thread-safe snapshot of the default-model profile the API server serves
    /// (refreshed whenever routes change).
    private let apiProfileBox = ProfileBox()

    init() {
        // Bedrock routes sign their requests with credentials the AWS CLI exports for their profile.
        AWSAccounts.install()
        transport = AppTransport(config: config)
        spark = SparkController(config: config, transport: transport)
        // Guardian's shared state: prompts on submit, turn durations for the
        // multitenant ETA cache, and the transport back-reference for the
        // sign-in-time ETA blend.
        let guardian = guardian
        guardian.transport = transport
        transport.guardianEtaPush = { kind, scope, seconds in
            guardian.pushEta(kindRawValue: kind, scope: scope, seconds: seconds)
        }
        // A prompt sent while signed into Guardian lands in the account's
        // prompt history (the service deduplicates).
        transport.guardianSync = { record, chatID in
            let outcome: String? = {
                switch record.outcome {
                case .none: return nil
                case .completed: return "completed"
                case .blocked: return "needs you"
                case .failed: return "failed"
                case .stopped: return "stopped"
                }
            }()
            Task { await guardian.syncPrompts([
                .init(id: record.id, text: record.text, at: record.at, outcome: outcome, chatID: chatID),
            ]) }
        }
        // Requests to models that aren't private go through the sensitive-data shield: the user's settings, and
        // every secret in the Credentials Vault.
        let vault = transport.vault
        let policy = ShieldPolicy(settings: config.shield, vaultValues: { vault.valuesForRedaction().map(\.value) })
        ProviderClients.shield = policy
        mode = WorkspaceMode(rawValue: config.lastMode) ?? .chat
        showWizard = !config.wizardCompleted || !config.isConfigured
        if IsolatedRun.defaults.bool(forKey: LegacySettingsImport.noticePendingKey) {
            renameNotice = LaunchMigration.renameNotice
        }
        if let failure = LaunchMigration.failure {
            transport.banner = "\(AppIdentity.name) couldn't move its data to its own folder yet (\(failure)), so it is "
                + "working where \(AppIdentity.Legacy.name) kept it. It tries again the next time it opens."
        }

        let spark = spark
        let config = config, transport = transport
        config.onShieldChanged = {
            policy.current = config.shield
            // Clients are made with the engines: the next turn makes them again.
            transport.resetRouteCache()
        }
        transport.isServerSwitching = { spark.isSwitchingMainModel }
        transport.onSwapCommand = { arg, vm in
            Task { @MainActor in await spark.handleCommand(arg, in: vm) }
        }
        transport.modelServerConfigured = { spark.isConfigured }
        transport.modelServerDescribe = { request in spark.describe(request) }
        transport.modelServerPerform = { request in await spark.perform(request) }
        spark.startMonitoring()

        // The agent's scheduling tools work on the same store as the calendar.
        transport.scheduleFromAgent = { [weak self] automation in self?.saveAutomation(automation) }
        transport.scheduledList = { [weak self] in self?.automations.currentStore().automations ?? [] }
        transport.scheduledCancel = { [weak self] id in
            guard let self, self.automations.currentStore().automation(id: id) != nil else { return false }
            self.deleteAutomation(id: id)
            return true
        }

        // The agent's file writes drive the editor's live reload.
        transport.onFilesChanged = { [weak self] changes in
            self?.code.applyExternalChanges(changes)
        }

        // Automation run records flow back into the persisted store.
        transport.schedulerRecord = { [weak self] id, status, duration, sessionID, detail in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.automations.recordRun(id: id, status: status, duration: duration,
                                           sessionID: sessionID, detail: detail)
                self.persistAutomations()
            }
        }
        loadAutomations()
        startAutomationTick()

        // The API server serves the live default model (route changes apply).
        apiProfileBox.set(config.activeProvider)
        // Replace the transport's routes-changed hook with one that ALSO
        // refreshes the API snapshot (the original call is preserved here).
        config.onRoutesChanged = { [weak self] in
            guard let self else { return }
            self.transport.refreshFleet()
            self.apiProfileBox.set(self.config.activeProvider)
        }
        if config.apiServerEnabled { startAPIServer() }

        // Reopen the most recent project so the app comes back where it left off.
        if let recent = config.liveRecentProjects.first {
            openProject(recent, activateSession: false)
        }

        // An interrupted task queue (crash, restart, quit) resumes automatically;
        // one the user deliberately stopped does not.
        resumeQueueIfNeeded()

        if mode == .agent { enterAgentMode() }
        refreshGuardianIfStale()
    }

    private func refreshFleetRoutes() {
        // AppConfig.onRoutesChanged already fired the transport's own refresh;
        // this hook is for app-layer reactions (the API snapshot above).
    }

    /// If the last session left work in the queue and the user didn't explicitly
    /// stop it, start processing it again. Requires a configured model — we never
    /// want to auto-fail a whole queue because the Spark is down at launch.
    func resumeQueueIfNeeded() {
        guard config.isConfigured,
              config.queueResumeOnLaunch,
              !config.queuePaused,
              transport.queue.nextTask != nil else { return }
        transport.startQueue()
    }

    var selectedSession: SessionVM? { transport.selected }

    func dismissRenameNotice() {
        renameNotice = nil
        IsolatedRun.defaults.removeObject(forKey: LegacySettingsImport.noticePendingKey)
    }

    /// Show or hide the plan panel.
    func togglePlan() {
        withAnimation(.easeInOut(duration: 0.18)) { config.planPanelOpen.toggle() }
    }

    /// Open the Amazon Bedrock guide — from the start, or on one page for an existing route
    /// (change its model, sign in again).
    func showBedrockGuide(page: BedrockPage = .welcome, route: ProviderProfile? = nil) {
        bedrockGuide = BedrockGuideRequest(page: page, route: route)
    }

    /// Open the "Connect my Spark Swapper" guide (a connection code, or an address and login).
    func showSwapperGuide(closing sheet: Bool = false) {
        openGuide(closing: sheet) { $0.swapperGuide = SwapperGuideRequest() }
    }

    /// Open the "Connect a subscription plan" guide (GLM, Kimi, Qwen, OpenAI).
    func showPlanGuide(closing sheet: Bool = false) {
        openGuide(closing: sheet) { $0.planGuide = PlanGuideRequest() }
    }

    /// Open a guide's sheet. From another sheet (the wizard, Settings), that one closes first so this one can open.
    private func openGuide(closing sheet: Bool, _ open: @escaping @MainActor (AppModel) -> Void) {
        guard sheet || showSettings || showWizard else {
            open(self)
            return
        }
        showSettings = false
        showWizard = false
        Task { @MainActor in
            // Let the sheet finish closing before the next one opens.
            try? await Task.sleep(nanoseconds: 400_000_000)
            open(self)
        }
    }

    // MARK: - Projects

    /// Ask for a folder (or several — a multi-folder session) and adopt them.
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open Project"
        panel.message = "Choose the folder the agent should work in — ⌘-click to add more folders to work across."
        if let project { panel.directoryURL = project }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        if urls.count == 1 {
            openProject(urls[0], additional: additionalProjects)
        } else {
            openProject(urls[0], additional: Array(urls.dropFirst()))
        }
    }

    /// Add one more folder to the current session's working set.
    func addFolder() {
        // With a chat open, the folder joins that chat alone.
        if let session = selectedSession {
            addFolder(to: session)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Folders the agent also works in, alongside the current project."
        if let project { panel.directoryURL = project }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        additionalProjects.append(contentsOf: panel.urls.filter { new in
            new.standardizedFileURL != project?.standardizedFileURL &&
            !additionalProjects.contains { $0.standardizedFileURL == new.standardizedFileURL }
        })
        if let project { transport.adoptProject(project, additional: additionalProjects) }
    }

    /// Add folders to one chat: "integrate this folder with that one".
    func addFolder(to session: SessionVM) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Chat"
        panel.message = "Folders this chat also works in, alongside \(session.projectName ?? "its own folder")."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        transport.addFolders(panel.urls, to: session)
    }

    /// Remove one additional folder from the working set.
    func removeFolder(_ url: URL) {
        additionalProjects.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if let project { transport.adoptProject(project, additional: additionalProjects) }
    }

    /// Adopt `url` as the project: it becomes the agent's working directory,
    /// the permission boundary, and the root of the file tree. `additional`
    /// are extra folders the agent works across.
    func openProject(_ url: URL, additional: [URL]? = nil, activateSession: Bool = true,
                     remember: Bool = true) {
        project = url
        if let additional {
            additionalProjects = additional
        } else {
            // Restore the set this project was last opened with.
            additionalProjects = (config.additionalFolders[url.path] ?? []).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if remember {
            config.additionalFolders[url.path] = additionalProjects.map(\.path)
            config.touchProject(url.path)
        }
        transport.adoptProject(url, additional: additionalProjects)
        code.open(root: url)

        guard activateSession else { return }
        // Return to this project's most recent chat rather than piling up
        // empty ones.
        if let existing = transport.sessions.first(where: { $0.cwd == url.path && !$0.isAgent }) {
            select(existing.id)
        } else {
            _ = newChat()
        }
    }

    func closeProject() {
        project = nil
        additionalProjects = []
        transport.adoptProject(nil)
        code.close()
    }

    func forgetProject(_ url: URL) {
        config.forgetProject(url.path)
        if project == url { closeProject() }
    }

    // MARK: - Automations

    private func loadAutomations() {
        if let store = AutomationFile.load(from: automationFile) {
            automations.replaceStore(store)
        }
    }

    private func persistAutomations() {
        do {
            try AutomationFile.save(automations.currentStore(), to: automationFile)
        } catch {
            transport.reportSaveFailure("your automations", error.localizedDescription)
        }
    }

    /// The 20-second tick: any schedule that has come due runs in its own
    /// chat. One loop for the app's lifetime; cheap when nothing is due.
    private func startAutomationTick() {
        automationTick?.cancel()
        automationTick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self else { return }
                await self.checkAutomations()
            }
        }
    }

    private func checkAutomations() {
        let due = automations.dueAutomations(now: .now)
        guard !due.isEmpty else { return }
        for automation in due {
            // Already being run by a previous tick (a long unattended run):
            // the next-run stamp lands when its record is written.
            guard !transport.runningAutomations.contains(automation.id) else { continue }
            transport.runAutomation(automation)
        }
    }

    /// Add or update an automation (UI), persisting the store.
    func saveAutomation(_ automation: Automation) {
        var store = automations.currentStore()
        if store.automation(id: automation.id) != nil { store.update(automation) } else { store.add(automation) }
        automations.replaceStore(store)
        persistAutomations()
    }

    func deleteAutomation(id: String) {
        var store = automations.currentStore()
        store.remove(id: id)
        automations.replaceStore(store)
        persistAutomations()
    }

    func toggleAutomation(id: String) {
        var store = automations.currentStore()
        store.toggle(id: id)
        automations.replaceStore(store)
        persistAutomations()
    }

    func runAutomationNow(_ id: String) {
        guard let automation = automations.currentStore().automation(id: id) else { return }
        transport.runAutomation(automation)
    }

    /// Import OpenClaw's scheduled tasks (jobs.json) into the harness library.
    /// Returns how many were imported.
    func importOpenClawJobs(from url: URL) -> Int {
        let jobs = OpenClawCompat.importJobs(from: url)
        guard !jobs.isEmpty else { return 0 }
        var store = automations.currentStore()
        for job in jobs where store.automation(id: job.id) == nil {
            store.add(job)
        }
        automations.replaceStore(store)
        persistAutomations()
        return jobs.count
    }

    // MARK: - API server

    func startAPIServer() {
        guard apiServer == nil else { return }
        let port = UInt16(clamping: config.apiServerPort)
        let box = apiProfileBox
        let server = LocalAPIServer(port: port == 0 ? 8337 : port) { box.get() }
        do {
            try server.start()
            apiServer = server
        } catch {
            apiServer = nil
            transport.note("The local API server couldn't start: \(error.localizedDescription)")
        }
    }

    func stopAPIServer() {
        apiServer?.stop()
        apiServer = nil
    }

    var apiServerRunning: Bool { apiServer?.isRunning ?? false }
    var apiServerPort: Int? { apiServer.map { Int($0.boundPort ?? UInt16(config.apiServerPort)) } }

    func apiServerSettingChanged() {
        if config.apiServerEnabled { startAPIServer() } else { stopAPIServer() }
    }

    // MARK: - Sessions

    func select(_ id: String?) {
        transport.selectedID = id
        if let session = transport.selected {
            transport.hydrate(session)
            // Make sure the context gauge has a number before the user asks.
            transport.ensureContextProbe()
            // Following a chat into its project keeps both modes in step.
            // An Agent thread's folder isn't a project; a worktree is temporary,
            // so it stays out of the recent projects.
            if !session.isAgent, let cwd = session.cwd, cwd != project?.path {
                openProject(URL(fileURLWithPath: cwd), activateSession: false, remember: session.worktree == nil)
            }
            if session.worktree != nil {
                Task { await transport.refreshWorktreeStatus(session) }
            }
        }
    }

    @discardableResult
    func newChat() -> SessionVM {
        if mode == .agent { return newAgentThread() }
        let session = transport.newSession(cwd: project?.path)
        // Chat mode keeps its own history: a conversation, even about a project.
        transport.setBucket(mode == .code ? .code : .chat, of: session)
        transport.ensureContextProbe()
        return session
    }

    // MARK: - Guardian's models and people

    /// What this account may run, as routes: the proxy's models and each AI host's. A failure leaves what's
    /// there, so an expired sign-in or a network hiccup never takes the selection away.
    func refreshGuardian() async {
        guard let client = guardian.client else { return }
        lastGuardianRefresh = .now
        let proxy = (try? await client.models()) ?? []
        let local = (try? await client.localModels()) ?? []
        guardianPeople = ((try? await client.people()) ?? []).filter { !$0.isRetired }
        guard !proxy.isEmpty || !local.isEmpty else { return }
        let localIDs = Set(local.map(\.modelId))
        let hosted = proxy.filter { !localIDs.contains($0.id) }
        let fresh = client.routes(for: hosted) + client.routes(forLocal: local, proxied: Set(proxy.map(\.id)))
        var routes = config.providers.filter { $0.kind != .guardian }
        let old = config.providers.filter { $0.kind == .guardian }
        for var route in fresh {
            // Keep what the user set on a route they already had.
            if let existing = old.first(where: { $0.routeID == route.routeID }) {
                route.subagentWorker = existing.subagentWorker
                route.subagentParallel = existing.subagentParallel
                route.enabled = existing.enabled
                route.backup = existing.backup
                route.isPrivate = existing.isPrivate
            }
            routes.append(route)
        }
        // The route in use stays until the user picks another, even if the plan stopped listing it.
        if let active = old.first(where: { $0.routeID == config.activeRoute }), !fresh.contains(where: { $0.routeID == active.routeID }) {
            routes.append(active)
        }
        config.providers = routes
    }

    /// At most once a minute, so a new AI host or person shows up without a restart.
    func refreshGuardianIfStale() {
        guard guardian.isSignedIn, Date().timeIntervalSince(lastGuardianRefresh) > 60 else { return }
        Task { await refreshGuardian() }
    }

    /// Ask for a name, then start a chat in a new worktree of `project`.
    func requestWorktreeChat(project: URL? = nil) {
        guard let target = project ?? self.project else {
            chooseProject()
            return
        }
        worktreeRequest = WorktreeRequest(project: target)
    }

    func startWorktreeChat(project: URL, title: String) async throws {
        if mode == .agent || mode == .automations { mode = .code }
        let session = try await transport.newWorktreeSession(project: project, title: title)
        select(session.id)
    }

    // MARK: - Agent mode

    /// The agent's own scratch folder. Not a project.
    private var agentFolder: URL {
        let folder = AppPaths.support.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func modeChanged(from old: WorkspaceMode) {
        guard old != mode else { return }
        if mode == .agent {
            lastChatID = transport.selected.flatMap { $0.isAgent ? nil : $0.id } ?? lastChatID
            enterAgentMode()
        } else if old == .agent {
            lastAgentID = transport.selected.flatMap { $0.isAgent ? $0.id : nil } ?? lastAgentID
            let chats = transport.sessions.filter { !$0.isAgent }
            select(chats.first { $0.id == lastChatID }?.id ?? chats.first?.id)
        }
    }

    private func enterAgentMode() {
        let threads = transport.sessions.filter(\.isAgent)
        if let back = threads.first(where: { $0.id == lastAgentID }) ?? threads.first(where: { $0.person == nil }) {
            select(back.id)
        } else {
            newAgentThread()
        }
        refreshGuardianIfStale()
    }

    @discardableResult
    func newAgentThread(person: GuardianPerson? = nil) -> SessionVM {
        let session = transport.newSession(cwd: agentFolder.path)
        session.isAgent = true
        session.person = person
        let title = person?.displayName ?? "Agent"
        transport.renameSession(session.id, to: title, byUser: person != nil)
        transport.log.updateMeta(session.id) {
            $0.kind = "agent"
            $0.person = person
        }
        transport.ensureContextProbe()
        return session
    }

    /// A regular conversation — no project, even while one is open.
    @discardableResult
    func newPlainChat() -> SessionVM {
        mode = .chat
        let session = transport.newSession(cwd: nil)
        transport.ensureContextProbe()
        return session
    }

    /// A person's own ongoing thread, so each keeps their own conversation.
    func openThread(with person: GuardianPerson) {
        if mode != .agent { mode = .agent }
        if let existing = transport.sessions.first(where: { $0.isAgent && $0.person?.id == person.id }) {
            select(existing.id)
        } else {
            let session = newAgentThread(person: person)
            select(session.id)
        }
    }

    /// Back to the main thread after talking to a person.
    func openMainAgentThread() {
        if let main = transport.sessions.first(where: { $0.isAgent && $0.person == nil }) {
            select(main.id)
        } else {
            newAgentThread()
        }
    }

    /// Returns whether the prompt was taken (see `AppTransport.send`).
    @discardableResult
    func send(_ text: String, in session: SessionVM, attachments: [MessageAttachment] = []) -> Bool {
        transport.send(text, sessionID: session.id, attachments: attachments)
    }

    // MARK: - Stopping

    func stopSelected() {
        guard let session = selectedSession, session.running else { return }
        transport.stopSession(session.id)
    }

    func stopAll() { transport.stopAll() }

    /// Jump to a chat by id (used by the queue's "Open chat").
    func openSession(_ id: String) {
        mode = .chat
        select(id)
    }

    var anythingRunning: Bool { transport.anythingRunning }
}
