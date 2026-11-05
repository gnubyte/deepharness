import SwiftUI
import Observation
import VisionHarnessCore

/// Which half of the app the window is showing.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case chat, code, automations
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "Chat"
        case .code: "Code"
        case .automations: "Automations"
        }
    }
    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .automations: "clock.badge.checkmark"
        }
    }
}

enum SettingsTab: Hashable { case general, models, spark, guardian, skills, computer, plugins, editor, automations }
enum SkillsAction: Equatable { case generate, importSkills, newManual }

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
        didSet { config.lastMode = mode.rawValue }
    }
    /// Presented over everything on first run, and on demand afterwards.
    var showWizard = false
    var showSettings = false
    var showMemoryAndSkills = false
    /// The task-queue side panel.
    var showQueuePanel = false
    /// The credential vault window.
    var showVault = false
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
        spark.startMonitoring()

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

    /// Remove one additional folder from the working set.
    func removeFolder(_ url: URL) {
        additionalProjects.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if let project { transport.adoptProject(project, additional: additionalProjects) }
    }

    /// Adopt `url` as the project: it becomes the agent's working directory,
    /// the permission boundary, and the root of the file tree. `additional`
    /// are extra folders the agent works across.
    func openProject(_ url: URL, additional: [URL]? = nil, activateSession: Bool = true) {
        project = url
        if let additional {
            additionalProjects = additional
        } else {
            // Restore the set this project was last opened with.
            additionalProjects = (config.additionalFolders[url.path] ?? []).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        config.additionalFolders[url.path] = additionalProjects.map(\.path)
        config.touchProject(url.path)
        transport.adoptProject(url, additional: additionalProjects)
        code.open(root: url)

        guard activateSession else { return }
        // Return to this project's most recent chat rather than piling up
        // empty ones.
        if let existing = transport.sessions.first(where: { $0.cwd == url.path }) {
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
        try? AutomationFile.save(automations.currentStore(), to: automationFile)
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
            if let cwd = session.cwd, cwd != project?.path {
                openProject(URL(fileURLWithPath: cwd), activateSession: false)
            }
        }
    }

    @discardableResult
    func newChat() -> SessionVM {
        let session = transport.newSession(cwd: project?.path)
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

    func send(_ text: String, in session: SessionVM, attachments: [MessageAttachment] = []) {
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
