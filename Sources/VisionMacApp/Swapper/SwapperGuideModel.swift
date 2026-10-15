import Foundation
import Observation
import VisionHarnessCore

/// The pages of the "Connect my Spark Swapper" guide, in order.
enum SwapperPage: Int, CaseIterable, Comparable {
    case code, check, model, use, done

    static func < (a: SwapperPage, b: SwapperPage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .code: "Paste the code"
        case .check: "Check it"
        case .model: "Pick the model"
        case .use: "How DSH uses it"
        case .done: "Say hello"
        }
    }
}

/// How a newly connected model is used: the model you talk to, a subagent server, or a backup that takes over
/// when the primary stops answering.
enum ModelRole: String, CaseIterable, Identifiable {
    case primary, subagent, backup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Primary"
        case .subagent: "Subagent"
        case .backup: "Backup"
        }
    }

    var detail: String {
        switch self {
        case .primary: "Answers you, and hands out side tasks. Whatever led before keeps helping as a subagent server."
        case .subagent: "Takes side tasks from the primary, in parallel."
        case .backup: "Takes over a turn when the primary stops answering."
        }
    }

    var icon: String {
        switch self {
        case .primary: "crown"
        case .subagent: "gearshape.2"
        case .backup: "arrow.triangle.branch"
        }
    }
}

/// What opens the guide.
struct SwapperGuideRequest: Identifiable {
    let id = UUID()
}

/// Everything the guide does to the outside world: the Swapper, the model, the app's settings.
@MainActor
protocol SwapperGuideBackend: AnyObject {
    /// Reach the Swapper a code names, with its certificate pinned, and read its status with the code's token.
    func check(_ code: SwapperConnectionCode) async throws -> SwapperStatus
    /// Sign in with an address and login, and read what the box says about itself (nothing is made on it yet).
    func login(address: String, username: String, password: String, pinned: String?) async throws -> SwapperConnect.LoginOutcome
    /// What to keep for a box signed in to with a password: an app token on a Swapper 2.0, else the password.
    func keep(_ connection: SwapperConnection, password: String) async throws -> (connection: SwapperConnection, secret: String)
    /// The boxes the app knows now.
    func boxes() -> [SwapperConnection]
    /// The status of a connected box.
    func status(of connection: SwapperConnection, secret: String) async throws -> SwapperStatus
    /// Ask the box to switch models.
    func swap(_ connection: SwapperConnection, secret: String, to key: String) async throws
    /// Start installing a model the box doesn't have yet; the install job.
    func install(_ connection: SwapperConnection, secret: String, key: String) async throws -> SwapperStatus.Job?
    /// The install running now, or the last one.
    func installJob(of connection: SwapperConnection, secret: String) async throws -> SwapperStatus.Job?
    /// Send one short message through the route and return the reply.
    func sayHello(route: ProviderProfile) async throws -> String
    /// Remember the box (its secret to the Keychain) with the route it serves.
    func register(_ connection: SwapperConnection, secret: String, route: ProviderProfile)
    func open(_ url: URL)
}

/// The "Connect my Spark Swapper" guide: from a connection code (or an address and login) to chatting with the
/// model the box serves. It checks the box with the code's certificate pinned, lets you pick (and switch to) a
/// model, asks how DSH should use it, then saves the route — address, key, certificate — and says hello.
///
/// The model is the state machine; `SwapperGuideBackend` is everything it does outside, so the flow is testable.
@MainActor
@Observable
final class SwapperGuideModel {
    @ObservationIgnored let backend: any SwapperGuideBackend
    @ObservationIgnored let config: AppConfig
    /// The route was saved: the host resets its caches.
    @ObservationIgnored var onSaved: (ProviderProfile) -> Void = { _ in }
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onLeave: () -> Void = {}

    private(set) var page: SwapperPage = .code
    var title: String { "Connect a Spark Swapper · \(page.title)" }
    var stepText: String { "Step \(page.rawValue + 1) of \(SwapperPage.allCases.count)" }

    // MARK: Page 1 — the code, or an address and login

    var codeText = "" {
        didSet { if codeText != oldValue { resetConnection() } }
    }
    var usesLogin = false {
        didSet { if usesLogin != oldValue { resetConnection() } }
    }
    // Another address or login is another sign-in: what was checked before doesn't carry over.
    var address = "" {
        didSet {
            guard address != oldValue else { return }
            trustedFingerprint = nil
            resetConnection()
        }
    }
    var username = "" {
        didSet { if username != oldValue { resetConnection() } }
    }
    var password = "" {
        didSet { if password != oldValue { resetConnection() } }
    }

    /// The code, when the text is one.
    var code: SwapperConnectionCode? { try? SwapperConnectionCode.decode(codeText) }

    /// What is wrong with the pasted text (nil while it is empty or fine).
    var codeProblem: String? {
        guard !codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code == nil else { return nil }
        return SwapperConnectionCode.invalidMessage
    }

    // MARK: Page 2 — checking

    private(set) var checking = false
    private(set) var checkError: String?
    /// A certificate to trust before the login is sent (address-and-login only).
    private(set) var untrustedFingerprint: String?
    private(set) var connection: SwapperConnection?
    private(set) var secret = ""
    private(set) var status: SwapperStatus?
    /// The model API: where the route points, its key, and the certificate it presents.
    private(set) var apiBase: String?
    private(set) var apiKey: String?

    // MARK: Page 3 — the model

    private(set) var selectedKey: String?
    private(set) var switching = false
    private(set) var switchError: String?
    private(set) var switchStep: String?
    private(set) var switchStarted: Date?
    /// The model being installed on the box.
    private(set) var installing: String?
    private(set) var installStep: String?
    private(set) var installLine: String?
    private(set) var installError: String?
    private(set) var installStarted: Date?
    /// Models installed during this guide: each is offered "Switch to it".
    private(set) var installed: Set<String> = []

    // MARK: Page 4 — how DSH uses it

    var role: ModelRole {
        didSet { roleChosen = true }
    }
    var isPrivate = true {
        didSet { privacyChosen = true }
    }
    /// The user picked a role / set the privacy (when the route exists already, only what they picked changes).
    private(set) var roleChosen = false
    private(set) var privacyChosen = false

    // MARK: Page 5 — save and say hello

    private(set) var saving = false
    /// Keeping the connection on the box (making its app token) didn't work.
    private(set) var saveError: String?
    private(set) var saved: ProviderProfile?
    private(set) var hello: String?
    private(set) var helloError: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var disposed = false
    /// How long to wait between status polls while a switch runs (tests shorten it).
    @ObservationIgnored var pollInterval: TimeInterval = 2

    init(backend: any SwapperGuideBackend, config: AppConfig) {
        self.backend = backend
        self.config = config
        role = config.mainRoute == nil ? .primary : .subagent
    }

    func dispose() {
        disposed = true
        task?.cancel()
    }

    private func resetConnection() {
        task?.cancel()
        checking = false
        checkError = nil
        untrustedFingerprint = nil
        connection = nil
        secret = ""
        apiBase = nil
        apiKey = nil
        status = nil
        selectedKey = nil
        saved = nil
        saveError = nil
        hello = nil
        helloError = nil
    }

    // MARK: Navigation

    var nextLabel: String {
        switch page {
        case .check: "Next"
        case .use: "Save and Say Hello"
        case .done: "Start Chatting"
        default: "Next"
        }
    }

    var canAdvance: Bool {
        switch page {
        case .code:
            if usesLogin {
                return !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
                    && !password.isEmpty
            }
            return code != nil
        case .check: return status != nil && !checking
        // The route is for what the box serves: another pick is switched to first (or "Keep" goes back).
        case .model: return selectedKey != nil && !switching && !needsSwitch && installing == nil
        case .use: return true
        case .done: return saved != nil && !saving
        }
    }

    func next() {
        guard canAdvance else { return }
        switch page {
        case .done: onFinish()
        default: if let following = SwapperPage(rawValue: page.rawValue + 1) { go(following) }
        }
    }

    func back() {
        if page == .code { onLeave(); return }
        // Once saved, going back doesn't unsave: the pages before only describe what was saved.
        go(SwapperPage(rawValue: page.rawValue - 1) ?? .code)
    }

    func go(_ target: SwapperPage) {
        page = target
        switch target {
        case .check where status == nil && !checking: runCheck()
        case .model where selectedKey == nil: selectedKey = status?.active ?? status?.installedModels.first?.key
        case .done where saved == nil && !saving: saveAndSayHello()
        default: break
        }
    }

    // MARK: Checking

    /// Check the code (or sign in with the address and login), then read what the box serves.
    func runCheck() {
        checking = true
        checkError = nil
        task?.cancel()
        task = Task {
            defer { checking = false }
            do {
                if usesLogin {
                    try await checkLogin()
                } else if let code {
                    let found = try await backend.check(code)
                    guard !disposed else { return }
                    connection = SwapperConnect.connection(for: code)
                    secret = code.token
                    apiBase = code.apiBase.absoluteString
                    apiKey = code.apiKey
                    status = found
                    noteFacts(found)
                }
                selectedKey = status?.active ?? status?.installedModels.first?.key
            } catch is CancellationError {
            } catch {
                checkError = Self.explain(error, address: usesLogin ? address : code?.swapperURL.absoluteString ?? "")
            }
        }
    }

    private func checkLogin() async throws {
        let outcome = try await backend.login(address: address, username: username.trimmingCharacters(in: .whitespaces),
                                              password: password, pinned: trustedFingerprint)
        switch outcome {
        case .needsTrust(let fingerprint):
            untrustedFingerprint = fingerprint
        case .connected(let made, let madeSecret, let info, let credentials):
            untrustedFingerprint = nil
            connection = made
            secret = madeSecret
            // The model API: what a 2.0 Swapper said, what an older one's credentials say, else its usual front.
            let host = URL(string: made.url)?.host ?? address
            apiBase = info?.apiBase ?? credentials?.apiBase ?? made.apiBase ?? "https://\(host):11443/v1"
            apiKey = info?.apiKey ?? credentials?.apiKey
            if connection?.apiBase == nil { connection?.apiBase = apiBase }
            let found = try await backend.status(of: made, secret: madeSecret)
            status = found
            noteFacts(found)
        }
    }

    /// The fingerprint the user chose to trust (address-and-login).
    private var trustedFingerprint: String?

    /// The user compared the fingerprint and trusts it: sign in again with it pinned.
    func trustCertificate() {
        guard let fp = untrustedFingerprint else { return }
        trustedFingerprint = fp
        untrustedFingerprint = nil
        runCheck()
    }

    private func noteFacts(_ s: SwapperStatus) {
        if let version = s.version { connection?.version = version }
        if let platform = s.platform { connection?.platform = platform }
        if let hostname = s.hostname { connection?.hostname = hostname }
    }

    /// A sentence for an error, naming the address when it couldn't be reached.
    static func explain(_ error: Error, address: String) -> String {
        if case SwapperError.transport = error {
            return "Couldn't reach the Swapper at \(address). The box may be switched off, or this Mac may be on another network."
        }
        return error.localizedDescription
    }

    // MARK: What it says

    /// "Connected to DGX Spark (spark-3f2a) — DGX Spark — serving Qwen3.8 27B (1M context)"
    var connectedLine: String? {
        guard let status, let connection else { return nil }
        let platform = SwapperPlatform.displayName(status.platform ?? connection.platform)
        let serving = status.activeModel.map { "serving \($0.title) (\(ModelSizes.short($0.window)) context)" }
            ?? "nothing is serving right now"
        return "Connected to \(connection.name) — \(platform) — \(serving)"
    }

    var boxName: String { connection?.name ?? "the box" }

    var selectedModel: SwapperStatus.Model? { selectedKey.flatMap { status?.models[$0] } }

    var servingModel: SwapperStatus.Model? { status?.activeModel }

    /// The picked model isn't the one serving: offer to switch.
    var needsSwitch: Bool {
        guard let selectedKey else { return false }
        return selectedKey != status?.active
    }

    func choose(_ key: String) {
        guard !switching, installing == nil, status?.models[key]?.isInstalled == true else { return }
        selectedKey = key
        switchError = nil
    }

    // MARK: Installing

    /// Install a model the box doesn't have yet, follow it to the end, then offer to switch to it.
    func install(_ key: String) {
        guard let connection, installing == nil, !switching,
              let target = status?.models[key], !target.isInstalled else { return }
        installing = key
        installError = nil
        installStep = "Starting…"
        installLine = nil
        installStarted = Date()
        task?.cancel()
        task = Task {
            defer { installing = nil; installStep = nil; installLine = nil }
            do {
                let started = try await backend.install(connection, secret: secret, key: key)
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    guard let job = try await backend.installJob(of: connection, secret: secret),
                          job.installingModel == key, started.map({ $0.id == job.id }) ?? true else { continue }
                    if job.isRunning {
                        installStep = job.currentStep?.label ?? "Working"
                        installLine = job.lastLogLine
                        continue
                    }
                    if job.state == "failed" {
                        installError = "The install failed: \(job.error ?? "unknown error")."
                        break
                    }
                    let fresh = try await backend.status(of: connection, secret: secret)
                    status = fresh
                    if fresh.models[key]?.isInstalled == true {
                        installed.insert(key)
                        selectedKey = key
                        switchError = nil
                    } else {
                        installError = "The install finished, but \(target.title) still isn't ready on \(connection.name)."
                    }
                    break
                }
            } catch SwapperError.installBusy {
                installError = "Another install is already running on \(connection.name). Wait for it to finish, then try again."
            } catch is CancellationError {
            } catch {
                installError = Self.explain(error, address: connection.url)
            }
        }
    }

    /// "Installing Qwen3.8 Flash · Downloading weights · 3m 12s"
    func installProgress(at now: Date = Date()) -> String? {
        guard let installing, let installStarted else { return nil }
        let title = status?.models[installing]?.title ?? installing
        let seconds = max(0, Int(now.timeIntervalSince(installStarted)))
        return "Installing \(title) on \(boxName) · \(installStep ?? "Working") · \(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }

    /// "Keep <current>": go back to the model serving now.
    func keepCurrent() {
        guard let active = status?.active else { return }
        selectedKey = active
        switchError = nil
    }

    // MARK: Switching

    /// Switch the box to the picked model and wait for it, showing the steps.
    func switchNow() {
        guard let connection, let key = selectedKey, !switching, installing == nil else { return }
        switching = true
        switchError = nil
        switchStep = "Asking \(connection.name) to switch…"
        switchStarted = Date()
        let earlierJob = status?.job?.id
        task?.cancel()
        task = Task {
            defer { switching = false }
            do {
                try await backend.swap(connection, secret: secret, to: key)
                var quietPolls = 0
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    let s = try await backend.status(of: connection, secret: secret)
                    status = s
                    // This switch's job (not one left over from before).
                    if let job = s.job, job.id != earlierJob, job.target == key {
                        if job.isRunning {
                            switchStep = job.currentStep?.label ?? "Working"
                            continue
                        }
                        if job.state == "failed" {
                            switchError = "Switching failed: \(job.error ?? "unknown error"). \(job.note ?? "")"
                                .trimmingCharacters(in: .whitespaces)
                            selectedKey = s.active ?? selectedKey
                        } else if s.active != key {
                            switchError = "The switch ended, but \(connection.name) isn't serving \(s.models[key]?.title ?? key)."
                        }
                        break
                    }
                    if s.busy { continue }
                    if s.active == key { break }
                    quietPolls += 1
                    if quietPolls >= 15 {
                        switchError = "\(connection.name) didn't start switching. Try again, or switch it on the Swapper's web page."
                        break
                    }
                }
            } catch SwapperError.notInstalled {
                switchError = "That model isn't installed on \(connection.name) yet — install it from Settings ▸ Model Servers."
            } catch is CancellationError {
            } catch {
                switchError = Self.explain(error, address: connection.url)
            }
            switchStep = nil
            installed.remove(key)
        }
    }

    /// "1m 05s" since the switch started.
    func switchElapsed(at now: Date = Date()) -> String {
        guard let switchStarted else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(switchStarted)))
        return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }

    // MARK: Saving

    /// The route this guide saves: OpenAI-compatible, named after the box, at its model API, its key (to the
    /// Keychain), the served model, the box's certificate pinned, the context window automatic, private, on.
    func route() -> ProviderProfile? {
        guard let connection, let apiBase else { return nil }
        let served = selectedModel?.served_id ?? status?.activeModel?.served_id ?? "model"
        var route = ProviderProfile(kind: .openAICompat, name: connection.name, baseURL: apiBase,
                                    apiKey: apiKey, model: served, vision: selectedModel?.vision,
                                    pinnedCertificate: connection.pinnedFingerprint, enabled: nil)
        route.isPrivate = AppConfig.privacy(isPrivate, for: route)
        return route
    }

    /// Save: on the address-and-login path the box first gets this app's token — only now, so a guide left
    /// halfway leaves nothing behind on the Swapper — then the route and the box are saved and it says hello.
    func saveAndSayHello() {
        guard let connection, route() != nil else { return }
        saveError = nil
        hello = nil
        helloError = nil
        guard case .login = connection.auth else { return finishSaving() }
        saving = true
        task?.cancel()
        task = Task {
            do {
                let kept = try await backend.keep(connection, password: secret)
                guard !disposed, !Task.isCancelled else { return }
                self.connection = kept.connection
                secret = kept.secret
                saving = false
                finishSaving()
            } catch is CancellationError {
                saving = false
            } catch {
                saving = false
                saveError = Self.explain(error, address: connection.url)
            }
        }
    }

    private func finishSaving() {
        guard let route = route(), let connection else { return }
        // A route already made for this box keeps the user's settings; a same-named one for another box is left
        // alone (the new route gets a name of its own).
        let boxes = backend.boxes()
        let (saved, isNew) = config.saveGuided(route, key: route.apiKey ?? "", privacyChosen: privacyChosen) { existing in
            if let owner = boxes.first(where: { $0.linkedRoutes.contains(existing.routeID) }) {
                return SwapperConnection.sameAddress(owner.url, connection.url)
            }
            return SwapperConnection.sameBase(existing.baseURL, route.baseURL)
        }
        if isNew || roleChosen {
            switch role {
            case .primary: config.makeMain(saved.routeID)
            case .subagent: config.setSubagentWorker(saved.routeID, true)
            case .backup: config.setBackup(saved.routeID, true)
            }
        }
        if config.mainRoute == nil { config.makeMain(saved.routeID) }
        var linked = connection
        if !linked.linkedRoutes.contains(saved.routeID) { linked.linkedRoutes.append(saved.routeID) }
        backend.register(linked, secret: secret, route: saved)
        self.saved = saved
        onSaved(saved)
        sayHello()
    }

    func sayHello() {
        guard var route = saved else { return }
        route.apiKey = apiKey
        saving = true
        helloError = nil
        task?.cancel()
        task = Task {
            defer { saving = false }
            do {
                hello = try await backend.sayHello(route: route)
            } catch is CancellationError {
            } catch {
                helloError = error.localizedDescription
            }
        }
    }
}
