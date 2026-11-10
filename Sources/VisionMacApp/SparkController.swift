import Foundation
import Observation
import VisionHarnessCore

/// One box running a Spark Swapper — a DGX Spark or a Strix Halo: how to reach it, what it is serving now, and
/// whether it is switching.
@MainActor
@Observable
final class SwapperBox: Identifiable {
    let id: String
    fileprivate(set) var connection: SwapperConnection
    fileprivate(set) var status: SwapperStatus?
    fileprivate(set) var lastError: String?
    /// A certificate the user hasn't approved yet (shown in Settings ▸ Model Servers).
    var untrustedFingerprint: String?
    fileprivate(set) var refreshing = false
    /// The install running on the box (or the last one Vision watched).
    fileprivate(set) var installJob: SwapperStatus.Job?
    fileprivate(set) var installError: String?
    /// Models installed while Vision watched: each is offered "Switch to It".
    fileprivate(set) var justInstalled: Set<String> = []
    /// Why the last thing asked of the box (a context window, pictures on or off) didn't happen. The box itself is
    /// fine — it said no — so this is shown next to the control, not as the box being unreachable.
    var actionError: String?
    /// What is being asked of the box right now ("Turning pictures off…"), so its controls wait.
    fileprivate(set) var working: String?
    /// What changed on the box lately, newest first (Swapper 2.2), and why it couldn't be read.
    fileprivate(set) var activity: [String] = []
    fileprivate(set) var activityError: String?
    /// When the box last answered.
    fileprivate(set) var lastAnswered: Date?

    @ObservationIgnored fileprivate var client: SparkSwapperClient?
    @ObservationIgnored fileprivate var watchedJob: String?
    @ObservationIgnored fileprivate var installWatch: Task<Void, Never>?

    init(connection: SwapperConnection) {
        self.id = connection.id
        self.connection = connection
    }

    var name: String { connection.name }
    var isOnline: Bool { status != nil && lastError == nil }
    /// Status checks that failed in a row. The last status a box gave is kept while it is silent, so after a few
    /// misses it is stale: a box that dropped off the network mid-switch must not look as if it switches forever
    /// (sending waits on a switch).
    fileprivate(set) var failures = 0
    static let staleAfterFailures = 3
    var isSwitching: Bool { failures < Self.staleAfterFailures && (status?.isSwitching ?? false) }

    /// "DGX Spark · Swapper 2.0.0"
    var summary: String {
        let version = (status?.version ?? connection.version).map { " · Swapper \($0)" } ?? ""
        return SwapperPlatform.displayName(status?.platform ?? connection.platform) + version
    }

    /// "Serving Qwen3.8 27B (1M context)", "Nothing is serving right now", or why it can't be reached.
    var servingLine: String {
        if let lastError { return lastError }
        guard let status else { return refreshing ? "Connecting…" : "Not checked yet" }
        guard let model = status.activeModel else { return "Nothing is serving right now" }
        return "Serving \(model.title) (\(ModelSizes.short(model.window)) context)"
    }

    /// Human-readable progress line for the banner while it switches.
    var progressLine: String? {
        guard let job = status?.job, job.isRunning else { return nil }
        let title = status?.models[job.target]?.title ?? job.target
        if failures > 0 {
            guard failures < Self.staleAfterFailures else {
                return "Lost contact with \(name) while it was switching to \(title). Still trying to reach it."
            }
            return "Switching \(name) to \(title) · the box isn't answering, trying again"
        }
        let step = job.currentStep?.label ?? "Working"
        let elapsed = Int(Date().timeIntervalSince1970 - job.started)
        return "Switching \(name) to \(title) · \(step) · \(elapsed / 60)m \(String(format: "%02d", elapsed % 60))s"
    }

    /// The Swapper's web page.
    var webPage: URL? { URL(string: connection.url) }

    /// Whether the box's Swapper has the context window, pictures and activity controls (2.2).
    var hasContextAndPictures: Bool {
        SwapperVersion.isAtLeast(status?.version ?? connection.version, SwapperVersion.contextAndPictures)
    }

    /// "Last answered 3 minutes ago" — for a box that has stopped answering; nil when it never did.
    func lastAnsweredText(now: Date = Date()) -> String? {
        guard let lastAnswered else { return nil }
        let seconds = Int(now.timeIntervalSince(lastAnswered))
        if seconds < 60 { return "Last answered moments ago" }
        if seconds < 3600 { return "Last answered \(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s") ago" }
        return "Last answered \(seconds / 3600) hour\(seconds / 3600 == 1 ? "" : "s") ago"
    }

    /// The model being installed right now.
    var installingKey: String? { installJob?.isRunning == true ? installJob?.installingModel : nil }

    /// "Installing Qwen3.8 Flash on DGX Spark (spark-3f2a) · Downloading weights · 3m 12s"
    var installProgressLine: String? {
        guard let job = installJob, job.isRunning, let key = job.installingModel else { return nil }
        let title = status?.models[key]?.title ?? key
        let step = job.currentStep?.label ?? "Working"
        let elapsed = Int(Date().timeIntervalSince1970 - job.started)
        return "Installing \(title) on \(name) · \(step) · \(elapsed / 60)m \(String(format: "%02d", elapsed % 60))s"
    }
}

/// Drives the Spark Swappers from the app: which model each box serves, switching it, and following the switch
/// in every chat — every route whose address is the box's model API follows the newly served model.
///
/// The connections live in UserDefaults; their secrets (an app token, or a login's password) in the Keychain.
@MainActor
@Observable
final class SparkController {
    private let defaults: UserDefaults
    private let secrets: any SecretStore
    private weak var transport: AppTransport?
    private let config: AppConfig

    private(set) var boxes: [SwapperBox] = []
    /// The model the user picked in a menu, waiting for "Switch".
    var confirmTarget: SwitchRequest?

    struct SwitchRequest: Identifiable {
        let box: SwapperBox
        let model: SwapperStatus.Model
        var id: String { box.id + "|" + model.key }

        /// "takes about 11 minutes"
        var duration: String { model.switchDuration }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// How often an install is checked on, and how long a box may go without answering before Vision stops
    /// following it (tests shorten both).
    @ObservationIgnored var installPollInterval: TimeInterval = 2
    @ObservationIgnored var installSilenceLimit: TimeInterval = 300

    init(config: AppConfig, transport: AppTransport, defaults: UserDefaults = IsolatedRun.defaults,
         secrets: any SecretStore = AppSecrets.keychain) {
        self.config = config
        self.transport = transport
        self.defaults = defaults
        self.secrets = secrets
        boxes = SwapperConnectionStore.load(defaults: defaults, secrets: secrets, routes: config.providers).map(SwapperBox.init)
    }

    // MARK: Boxes

    var isConfigured: Bool { !boxes.isEmpty }

    func box(id: String) -> SwapperBox? { boxes.first { $0.id == id } }

    /// The box serving `route`, if one does.
    func box(serving route: ProviderProfile?) -> SwapperBox? {
        guard let route else { return nil }
        return boxes.first { $0.connection.serves(route) }
    }

    /// The box behind the main model.
    var primaryBox: SwapperBox? { box(serving: config.mainRoute) }

    /// True while the box behind the main model switches models: sending waits for it.
    var isSwitchingMainModel: Bool { primaryBox?.isSwitching ?? false }

    var switchingBoxes: [SwapperBox] { boxes.filter(\.isSwitching) }

    /// Add a box, or update the one already known at the same address. `secret` is its token or password
    /// (to the Keychain).
    @discardableResult
    func add(_ connection: SwapperConnection, secret: String?) -> SwapperBox {
        var connection = connection
        if let existing = boxes.first(where: { SwapperConnection.sameAddress($0.connection.url, connection.url) }) {
            // Keep its identity (and its links) — it is the same box.
            connection.id = existing.id
            connection.linkedRoutes = Array(Set(existing.connection.linkedRoutes + connection.linkedRoutes)).sorted()
            existing.connection = connection
            existing.client = nil
            existing.lastError = nil
            existing.untrustedFingerprint = nil
            SwapperConnectionStore.setSecret(secret, for: connection, secrets: secrets)
            persist()
            return existing
        }
        SwapperConnectionStore.setSecret(secret, for: connection, secrets: secrets)
        let box = SwapperBox(connection: connection)
        boxes.append(box)
        persist()
        return box
    }

    func remove(_ box: SwapperBox) {
        SwapperConnectionStore.setSecret(nil, for: box.connection, secrets: secrets)
        boxes.removeAll { $0.id == box.id }
        persist()
    }

    func rename(_ box: SwapperBox, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        box.connection.name = trimmed
        persist()
    }

    /// Remember that `route` was made for `box` — and for no other box, so a route is never followed by two.
    func link(_ route: ProviderProfile, to box: SwapperBox) {
        for other in boxes where other.id != box.id && other.connection.linkedRoutes.contains(route.routeID) {
            other.connection.linkedRoutes.removeAll { $0 == route.routeID }
        }
        if !box.connection.linkedRoutes.contains(route.routeID) { box.connection.linkedRoutes.append(route.routeID) }
        persist()
    }

    /// Trust the certificate a box presented (the user compared the fingerprint) — for the Swapper and for the
    /// box's routes on it, whose model front (:11443) presents the same certificate.
    func trustPresentedCertificate(_ box: SwapperBox) {
        guard let fp = box.untrustedFingerprint else { return }
        box.connection.pinnedFingerprint = fp
        box.untrustedFingerprint = nil
        box.lastError = nil
        box.client = nil
        persist()
        let host = box.connection.host
        for index in config.providers.indices {
            let route = config.providers[index]
            guard box.connection.serves(route), let url = URL(string: route.baseURL), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == host, route.pinnedCertificate != fp else { continue }
            config.providers[index].pinnedCertificate = fp
        }
        Task { await refresh(box) }
    }

    func forgetCertificate(_ box: SwapperBox) {
        box.connection.pinnedFingerprint = nil
        box.client = nil
        persist()
    }

    private func persist() {
        SwapperConnectionStore.save(boxes.map(\.connection), defaults: defaults)
    }

    private func client(_ box: SwapperBox) throws -> SparkSwapperClient {
        if let client = box.client { return client }
        guard let made = SwapperConnectionStore.client(for: box.connection, secrets: secrets) else {
            throw SwapperError.notConfigured
        }
        box.client = made
        return made
    }

    // MARK: Status

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for box in boxes {
                group.addTask { await self.refresh(box) }
            }
        }
    }

    func refresh(_ box: SwapperBox) async {
        box.refreshing = true
        defer { box.refreshing = false }
        do {
            let s = try await client(box).status()
            let wasRunning = box.status?.job?.isRunning ?? false
            box.status = s
            box.lastError = nil
            box.failures = 0
            box.lastAnswered = Date()
            box.untrustedFingerprint = nil
            noteFacts(s, of: box)
            // An install started elsewhere (the web page, before a relaunch): follow it too.
            if let install = s.install_job, install.isRunning, box.installWatch == nil {
                box.installJob = install
                watchInstall(box)
            }
            if let job = s.job, !job.isRunning, wasRunning || box.watchedJob == job.id {
                finished(job, on: box, status: s)
            }
            if s.isSwitching { startMonitoring() }
        } catch let e as SwapperError {
            if case .untrustedCertificate(let fp) = e { box.untrustedFingerprint = fp }
            box.lastError = e.errorDescription
            box.failures += 1
        } catch {
            box.lastError = error.localizedDescription
            box.failures += 1
        }
    }

    /// A Swapper 2.0 says what it is: keep the connection's details current.
    private func noteFacts(_ s: SwapperStatus, of box: SwapperBox) {
        var changed = box.connection
        if let version = s.version { changed.version = version }
        if let platform = s.platform { changed.platform = platform }
        if let hostname = s.hostname { changed.hostname = hostname }
        if changed != box.connection {
            box.connection = changed
            persist()
        }
    }

    /// Poll quickly while a box switches, slowly otherwise.
    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                let fast = !self.switchingBoxes.isEmpty
                try? await Task.sleep(nanoseconds: (fast ? 2 : 30) * 1_000_000_000)
            }
        }
    }

    // MARK: Switching

    /// Ask to switch (the UI confirms via `confirmTarget`).
    func request(_ model: SwapperStatus.Model, on box: SwapperBox) {
        guard model.key != box.status?.active, model.isInstalled else { return }
        confirmTarget = SwitchRequest(box: box, model: model)
    }

    /// Switch now. Returns an error message, or nil when the swap started.
    @discardableResult
    func swap(_ box: SwapperBox, to key: String) async -> String? {
        do {
            try await client(box).swap(to: key)
            box.justInstalled.remove(key)
            await refresh(box)
            box.watchedJob = box.status?.job?.id
            startMonitoring()
            let title = box.status?.models[key]?.title ?? key
            transport?.broadcast("Switching \(box.name) to **\(title)**… chats will pick it up automatically when it is ready.")
            return nil
        } catch SwapperError.notInstalled {
            // Not the box's fault: say so on the request, not as the box's state.
            box.actionError = Self.notInstalledMessage(box)
            return Self.notInstalledMessage(box)
        } catch let e as SwapperError {
            // A box that answered "no" (already switching, unknown model) is reachable: only a failure to reach or
            // sign in to it is the box's state.
            if Self.isRefusal(e) {
                box.actionError = e.errorDescription
            } else {
                box.lastError = e.errorDescription
            }
            return e.errorDescription
        } catch {
            box.lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

    static func notInstalledMessage(_ box: SwapperBox) -> String {
        "That model isn't installed on \(box.name) yet — install it from Settings ▸ Model Servers."
    }

    /// The box answered and said no (as opposed to not answering, or not letting Vision in).
    static func isRefusal(_ error: SwapperError) -> Bool {
        switch error {
        case .server, .refused, .needsUpdate, .installBusy, .notInstalled, .unsupported: true
        case .notConfigured, .untrustedCertificate, .certificateMismatch, .badLogin, .revoked, .transport: false
        }
    }

    /// Why something asked of a box failed, noted where it belongs: a "no" from the box next to its controls
    /// (`actionError`), a box that can't be reached or won't let Vision in as the box's state (`lastError`).
    private func noteFailure(_ error: any Error, on box: SwapperBox) -> String {
        guard let known = error as? SwapperError else {
            box.lastError = error.localizedDescription
            return error.localizedDescription
        }
        let message = known.errorDescription ?? "The box couldn't do that."
        if Self.isRefusal(known) {
            box.actionError = message
        } else {
            box.lastError = message
        }
        return message
    }

    // MARK: Context window, pictures, activity (Swapper 2.2)

    /// Serve `key` with a `tokens` window. When it is serving, the box restarts it like a switch (and puts the old
    /// window back if the new one won't start); otherwise the choice waits for the next switch to it. Returns an
    /// error message, or nil.
    @discardableResult
    func setContext(_ box: SwapperBox, model key: String, tokens: Int) async -> String? {
        box.actionError = nil
        box.working = "Changing the context window…"
        defer { box.working = nil }
        let change: SwapperContextChange
        do {
            change = try await client(box).setContext(model: key, tokens: tokens)
        } catch {
            return noteFailure(error, on: box)
        }
        await refresh(box)
        let title = box.status?.models[key]?.title ?? key
        let window = ModelSizes.short(tokens)
        if change.isRestarting {
            box.watchedJob = change.job?.id ?? box.status?.job?.id
            startMonitoring()
            transport?.broadcast("Restarting **\(title)** on \(box.name) with a \(window) context window… chats pick it up when it is ready.")
        } else if box.status?.active != key {
            transport?.broadcast("\(title) on \(box.name) will serve a \(window) context window the next time it is switched to.")
        }
        return nil
    }

    /// Turn pictures (Qwen-Image next to the model) on or off. Returns an error message, or nil.
    @discardableResult
    func setPictures(_ box: SwapperBox, enabled: Bool) async -> String? {
        box.actionError = nil
        box.working = enabled ? "Turning pictures on…" : "Turning pictures off…"
        defer { box.working = nil }
        do {
            let result = try await client(box).setPictures(enabled)
            box.status?.pictures = Lenient(result)
            return nil
        } catch {
            return noteFailure(error, on: box)
        }
    }

    /// Read what changed on the box lately (newest first).
    func loadActivity(_ box: SwapperBox) async {
        do {
            let lines = try await client(box).activity()
            box.activity = Array(lines.reversed())
            box.activityError = nil
        } catch {
            box.activityError = (error as? SwapperError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Adding a model from Hugging Face (Swapper 2.1.2)

    /// Look a Hugging Face repo up on `box`: what it is and whether the box can run it. Nothing is downloaded.
    func inspectHuggingFace(_ link: String, on box: SwapperBox) async -> (found: SwapperHFInspection?, problem: String?) {
        do {
            return (try await client(box).inspectHuggingFace(link), nil)
        } catch {
            return (nil, (error as? SwapperError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Add a Hugging Face model to `box` and follow its install like any other.
    func addHuggingFace(_ link: String, on box: SwapperBox) async -> (added: SwapperHFAdded?, problem: String?) {
        do {
            let added = try await client(box).addHuggingFace(link)
            await refresh(box)
            if let job = added.job {
                box.installError = nil
                box.installJob = job
                watchInstall(box)
            }
            return (added, nil)
        } catch {
            return (nil, (error as? SwapperError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: The agent's model_server tool

    /// The box a request names: by the start of its name or host name; with no name, the box behind the main
    /// model, else the only box.
    private func pick(_ query: String?) -> (box: SwapperBox?, problem: String) {
        guard !boxes.isEmpty else { return (nil, SwapperError.notConfigured.errorDescription ?? "No box is set up.") }
        let names = boxes.map(\.name).joined(separator: ", ")
        if let query = query?.trimmingCharacters(in: .whitespaces).lowercased(), !query.isEmpty {
            let hits = boxes.filter { box in
                box.name.lowercased().hasPrefix(query) || box.name.lowercased().contains(query)
                    || (box.connection.hostname?.lowercased().hasPrefix(query) ?? false)
                    || (box.connection.host?.hasPrefix(query) ?? false)
            }
            if hits.count == 1 { return (hits[0], "") }
            return (nil, hits.isEmpty ? "No box matches “\(query)”. The boxes: \(names)."
                                      : "“\(query)” matches several boxes: \(hits.map(\.name).joined(separator: ", ")). Say more of the name.")
        }
        if let primary = primaryBox { return (primary, "") }
        if boxes.count == 1 { return (boxes[0], "") }
        return (nil, "There are several boxes (\(names)) and none is behind this chat's model: pass `box`.")
    }

    /// The model a request names on `box`, from its last status.
    private func model(_ query: String?, on box: SwapperBox) -> SwapperStatus.Model? {
        guard let status = box.status else { return nil }
        guard let query, !query.isEmpty else { return status.activeModel }
        return status.resolve(query).flatMap { status.models[$0] }
    }

    /// What a request would do, for the permission prompt.
    func describe(_ request: ModelServerRequest) -> String {
        let picked = pick(request.box)
        guard let box = picked.box else { return "Change a model server: \(picked.problem)" }
        let own = box.id == primaryBox?.id ? " The model answering this chat is on this box, so it pauses until the box is back." : ""
        switch request {
        case .status, .activity:
            return "Read \(box.name)'s status."
        case .switchModel(_, let query):
            let target = model(query, on: box)
            return "Switch \(box.name) to \(target?.title ?? query) (\(target?.switchDuration ?? "a few minutes")). The model it serves now stops.\(own)"
        case .setContext(_, let query, let tokens):
            let target = model(query, on: box)
            let serving = target != nil && target?.key == box.status?.active
            return "Serve \(target?.title ?? query ?? "the model") on \(box.name) with a \(ModelSizes.short(tokens)) context window."
                + (serving ? " It restarts (\(target?.switchDuration ?? "a few minutes")).\(own)" : " It applies the next time the model is switched to.")
        case .setPictures(_, let enabled):
            return "Turn pictures \(enabled ? "on" : "off") on \(box.name)."
        case .install(_, let query):
            let target = model(query, on: box)
            var size = ""
            if let summary = target?.install?.summary { size = " (\(summary))" }
            return "Download and install \(target?.title ?? query) on \(box.name)\(size)."
        case .addModel(_, let link, _, _):
            return "Add the Hugging Face model \(link) to \(box.name) and download it."
        }
    }

    /// Carry a `model_server` request out and say what happened, for the model to read.
    func perform(_ request: ModelServerRequest) async -> String {
        if case .status(let query) = request, query == nil {
            // Every box, when none is named.
            await refreshAll()
            guard !boxes.isEmpty else { return "Error: \(SwapperError.notConfigured.errorDescription ?? "no box is set up.")" }
            return boxes.map { box in
                box.status?.report(name: box.name, summary: box.summary)
                    ?? "\(box.name) — \(box.summary)\nNot reachable: \(box.lastError ?? "it hasn't answered yet.")"
            }.joined(separator: "\n\n")
        }
        let picked = pick(request.box)
        guard let box = picked.box else { return "Error: \(picked.problem)" }
        await refresh(box)
        guard let status = box.status, box.lastError == nil else {
            return "Error: \(box.name) can't be reached: \(box.lastError ?? "it hasn't answered.")"
        }
        let own = box.id == primaryBox?.id
        switch request {
        case .status:
            return status.report(name: box.name, summary: box.summary)
        case .activity:
            await loadActivity(box)
            if let problem = box.activityError { return "Error: \(problem)" }
            return box.activity.isEmpty ? "Nothing has changed on \(box.name) lately."
                                        : "\(box.name), newest first:\n" + box.activity.prefix(40).joined(separator: "\n")
        case .switchModel(_, let query):
            guard let target = model(query, on: box) else {
                return "Error: no model on \(box.name) matches “\(query)”. Keys: \(status.ordered.map(\.key).joined(separator: ", "))."
            }
            guard target.isInstalled else { return "Error: \(target.title) isn't installed on \(box.name). Use action install first." }
            if target.key == status.active { return "\(box.name) is already serving \(target.title)." }
            if status.isSwitching { return "Error: \(box.name) is already switching models. Wait for it to finish." }
            if let failure = await swap(box, to: target.key) { return "Error: \(failure)" }
            return "Switching \(box.name) to \(target.title) — it takes \(target.switchDuration). "
                + (own ? "You are running on this box: your next step waits until it answers again, then continues on the new model."
                       : "Chats on that box follow it when it is ready; call status to check.")
        case .setContext(_, let query, let tokens):
            guard let target = model(query, on: box) else {
                if let query { return "Error: no model on \(box.name) matches “\(query)”." }
                return "Error: nothing is serving on \(box.name), so say which `model`."
            }
            let choices = target.contextChoices
            guard !choices.isEmpty else {
                return "Error: \(target.title)'s context window can't be changed on \(box.name)" + (box.hasContextAndPictures ? "." : " (its Spark Swapper is older than \(SwapperVersion.contextAndPictures)).")
            }
            guard let choice = choices.first(where: { $0.tokens == tokens })
                    ?? choices.first(where: { $0.name.lowercased() == ModelSizes.short(tokens).lowercased() }) else {
                return "Error: \(target.title) serves \(choices.map(\.name).joined(separator: " or ")), not \(ModelSizes.short(tokens))."
            }
            let serving = target.key == status.active
            if serving && target.window == choice.tokens { return "\(target.title) already serves a \(choice.name) window." }
            if let failure = await setContext(box, model: target.key, tokens: choice.tokens) { return "Error: \(failure)" }
            guard serving else { return "Saved: \(target.title) will serve \(choice.name) the next time \(box.name) switches to it." }
            return "\(target.title) is restarting with a \(choice.name) window (\(target.switchDuration)); if it won't start, the box puts the old window back. "
                + (own ? "You are running on this box: your next step waits until it answers again." : "Call status to check.")
        case .setPictures(_, let enabled):
            guard let pictures = status.pictures?.value, pictures.isInstalled else {
                return "Error: pictures aren't set up on \(box.name)" + (box.hasContextAndPictures ? "." : " (its Spark Swapper is older than \(SwapperVersion.contextAndPictures)).")
            }
            if let failure = await setPictures(box, enabled: enabled) { return "Error: \(failure)" }
            return "Pictures are \(enabled ? "on" : "off") on \(box.name). \(box.status?.pictures?.value?.summary ?? "")"
        case .install(_, let query):
            guard let target = model(query, on: box) else {
                return "Error: no model on \(box.name) matches “\(query)”. Keys: \(status.ordered.map(\.key).joined(separator: ", "))."
            }
            if target.isInstalled { return "\(target.title) is already installed on \(box.name)." }
            await install(target.key, on: box)
            if let failure = box.installError { return "Error: \(failure)" }
            var size = ""
            if let summary = target.install?.summary { size = " (\(summary))" }
            return "Installing \(target.title) on \(box.name)\(size). The chat is told when it is done; call status to follow it."
        case .addModel(_, let link, let context, let install):
            do {
                let found = try await client(box).inspectHuggingFace(link)
                guard install else { return found.report() }
                guard found.canRun, found.catalog_key?.value == nil else { return "Error: not added.\n" + found.report() }
                let added = try await client(box).addHuggingFace(link, context: context)
                await refresh(box)
                if added.job != nil { watchInstall(box) }
                return "Added \(found.title ?? found.repo) to \(box.name) as `\(added.key)`. "
                    + (added.note ?? "It is downloading now; the chat is told when it is installed, then switch to it.")
            } catch {
                return "Error: \((error as? SwapperError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    // MARK: Installing

    /// Install a model the box doesn't have yet (POST /api/models/install) and follow it until it finishes.
    func install(_ key: String, on box: SwapperBox) async {
        box.installError = nil
        do {
            let job = try await client(box).installModel(key)
            box.installJob = job ?? SwapperStatus.Job(id: "starting", target: "install:model:\(key)", state: "running",
                                                      started: Date().timeIntervalSince1970)
            watchInstall(box)
        } catch SwapperError.installBusy {
            box.installError = "Another install is already running on \(box.name). Wait for it to finish, then try again."
        } catch let e as SwapperError {
            box.installError = e.errorDescription
        } catch {
            box.installError = error.localizedDescription
        }
    }

    /// Poll the install (GET /api/provisioning/job) until it is over, then re-read what the box has. A box that
    /// stops answering about it for `installSilenceLimit` is no longer followed, and Settings says so.
    func watchInstall(_ box: SwapperBox) {
        guard box.installWatch == nil else { return }
        box.installWatch = Task { [weak self] in
            defer { box.installWatch = nil }
            var silentSince: Date?
            while !Task.isCancelled {
                guard let interval = self?.installPollInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard let job = try? await self.client(box).provisioningJob() else {
                    let since = silentSince ?? Date()
                    silentSince = since
                    if Date().timeIntervalSince(since) >= self.installSilenceLimit {
                        let minutes = max(1, Int((self.installSilenceLimit / 60).rounded()))
                        box.installError = "\(box.name) hasn't answered about the install for \(minutes) minute\(minutes == 1 ? "" : "s"), so Vision stopped following it. It may still be installing — check its web page."
                        box.installJob = nil
                        return
                    }
                    continue
                }
                silentSince = nil
                box.installJob = job
                guard !job.isRunning else { continue }
                if job.state == "done", let key = job.installingModel {
                    box.justInstalled.insert(key)
                    let title = box.status?.models[key]?.title ?? key
                    self.transport?.broadcast("📦 \(title) is installed on \(box.name). Switch to it from the model menu or Settings ▸ Model Servers.")
                } else if job.state == "failed" {
                    box.installError = "The install failed: \(job.error ?? "unknown error")."
                }
                await self.refresh(box)
                return
            }
        }
    }

    private func finished(_ job: SwapperStatus.Job, on box: SwapperBox, status s: SwapperStatus) {
        box.watchedJob = nil
        // Every route on this box re-reads what it serves (and its window), so chats and subagents follow.
        transport?.resetRouteCache()
        let title = s.models[job.target]?.title ?? job.target
        if job.state == "done", let m = s.models[job.target] {
            transport?.broadcast("✅ \(box.name) is now serving **\(title)** (`\(m.served_id)`, \(m.window.formatted())-token context).")
        } else if job.state == "failed" {
            transport?.broadcast("⚠️ Switching \(box.name) to \(title) failed: \(job.error ?? "unknown error"). \(job.note ?? "")", error: true)
        }
    }

    /// `/swap`: every box's models; `/swap <model>` on the box behind the main model (else the only box); `/swap
    /// <box> <model>` names the box.
    func handleCommand(_ arg: String?, in vm: SessionVM) async {
        let command = SwapCommand.parse(arg, boxes: boxes.map(\.connection), primaryBox: primaryBox?.id)
        switch command {
        case .noBoxes:
            vm.note(SwapperError.notConfigured.errorDescription ?? "", role: .error)
        case .list:
            await refreshAll()
            vm.note(listing())
        case .whichBox(let model):
            let names = boxes.map { "**\($0.name)**" }.joined(separator: ", ")
            vm.note("Which box should switch to “\(model)”? You have several: \(names). Name it first, e.g. `/swap \(Self.shortName(boxes[0])) \(model)`.")
        case .switchModel(let id, let query):
            guard let box = box(id: id) else { return }
            await refresh(box)
            guard let s = box.status else {
                vm.note(box.lastError ?? "Couldn't read \(box.name)'s status.", role: .error)
                return
            }
            guard let key = s.resolve(query), let target = s.models[key] else {
                vm.note("No model on \(box.name) matches “\(query)”. Options: \(s.installedModels.map(\.key).joined(separator: ", ")).", role: .error)
                return
            }
            guard target.isInstalled else {
                vm.note(Self.notInstalledMessage(box), role: .error)
                return
            }
            if key == s.active {
                vm.note("\(box.name) is already serving \(target.title).")
                return
            }
            if s.isSwitching {
                vm.note("\(box.name) is already switching models; wait for it to finish.", role: .error)
                return
            }
            if let err = await swap(box, to: key) { vm.note(err, role: .error) }
        }
    }

    /// The first word of a box's name, for an example command ("dgx", "strix").
    private static func shortName(_ box: SwapperBox) -> String {
        (box.name.split(separator: " ").first.map(String.init) ?? box.name).lowercased()
    }

    /// `/swap`'s answer: each box and what it can serve.
    private func listing() -> String {
        var lines: [String] = []
        for box in boxes {
            lines.append("**\(box.name)** — \(box.summary)")
            guard let s = box.status else {
                lines.append("  \(box.lastError ?? "Not reachable right now.")")
                continue
            }
            for m in s.ordered {
                let mark = m.key == s.active ? "● serving" : (m.running ? "◌ loading" : "○")
                var line = "\(mark)  **\(m.title)** — `\(m.key)` · \(ModelSizes.short(m.window)) ctx"
                if let speed = m.speedText(roomForEstimate: true) { line += " · \(speed)" }
                if !m.isInstalled { line += " · Not installed" }
                lines.append(line)
            }
        }
        lines.append(boxes.count > 1
                     ? "Switch with `/swap <model>` (the box behind the main model), `/swap <box> <model>`, or the model menu under the composer."
                     : "Switch with `/swap <name>` or the model menu under the composer.")
        return lines.joined(separator: "\n")
    }

    /// The banner's lines while boxes switch (or install).
    var progressLines: [String] { boxes.compactMap(\.progressLine) + boxes.compactMap(\.installProgressLine) }

    /// Switch from a menu or a confirmation, where nothing else would show a failure: it is said in the chat.
    func swapReporting(_ box: SwapperBox, to key: String) async {
        if let failure = await swap(box, to: key) { transport?.broadcast(failure, error: true) }
    }
}

/// "1M", "512K" — a context window in a few characters.
enum ModelSizes {
    static func short(_ n: Int) -> String {
        n >= 1_000_000
            ? String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
            : "\(n / 1024)K"
    }
}
