import XCTest
import VisionHarnessCore
@testable import VisionMacApp

/// Everything the Swapper guide asks of the box and the app, answered from a script.
@MainActor
final class FakeSwapperBackend: SwapperGuideBackend {
    var checkResult: Result<SwapperStatus, Error> = .success(SwapperStatus())
    var loginOutcomes: [SwapperConnect.LoginOutcome] = []
    /// What successive status reads return (the last one repeats).
    var statuses: [SwapperStatus] = []
    var helloText = "Hello from your own box!"
    private(set) var calls: [String] = []
    private(set) var registered: [(SwapperConnection, String, ProviderProfile)] = []
    private(set) var hellos: [ProviderProfile] = []

    func check(_ code: SwapperConnectionCode) async throws -> SwapperStatus {
        calls.append("check:\(code.swapperURL.absoluteString)")
        return try checkResult.get()
    }

    func login(address: String, username: String, password: String, pinned: String?) async throws -> SwapperConnect.LoginOutcome {
        calls.append("login:\(address):\(username):\(pinned ?? "-")")
        return loginOutcomes.isEmpty ? .needsTrust(fingerprint: "AA") : loginOutcomes.removeFirst()
    }

    /// The token keeping a signed-in box makes (nil: an older Swapper, which keeps the password).
    var keptToken: String? = "sst_9f8e7d6c_kept"
    var keepError: Error?
    /// The boxes the app knows.
    var known: [SwapperConnection] = []

    func keep(_ connection: SwapperConnection, password: String) async throws -> (connection: SwapperConnection, secret: String) {
        calls.append("keep:\(password)")
        if let keepError { throw keepError }
        guard let keptToken else { return (connection, password) }
        var kept = connection
        kept.authKind = "token"
        kept.username = nil
        return (kept, keptToken)
    }

    func boxes() -> [SwapperConnection] { known }

    func status(of connection: SwapperConnection, secret: String) async throws -> SwapperStatus {
        calls.append("status:\(secret)")
        return statuses.count > 1 ? statuses.removeFirst() : statuses.first ?? SwapperStatus()
    }

    var swapError: Error?
    var installResult: Result<SwapperStatus.Job?, Error> = .success(nil)
    /// What successive install-job reads return (the last one repeats).
    var installJobs: [SwapperStatus.Job?] = []

    func swap(_ connection: SwapperConnection, secret: String, to key: String) async throws {
        calls.append("swap:\(key)")
        if let swapError { throw swapError }
    }

    func install(_ connection: SwapperConnection, secret: String, key: String) async throws -> SwapperStatus.Job? {
        calls.append("install:\(key)")
        return try installResult.get()
    }

    func installJob(of connection: SwapperConnection, secret: String) async throws -> SwapperStatus.Job? {
        calls.append("installJob")
        return installJobs.count > 1 ? installJobs.removeFirst() : installJobs.first ?? nil
    }

    func sayHello(route: ProviderProfile) async throws -> String {
        hellos.append(route)
        return helloText
    }

    func register(_ connection: SwapperConnection, secret: String, route: ProviderProfile) {
        registered.append((connection, secret, route))
    }

    func open(_ url: URL) {}
}

@MainActor
final class SwapperGuideModelTests: XCTestCase {
    private var suites: [String] = []
    private var secrets = MemorySecretStore()
    private let fingerprint = (1...32).map { String(format: "%02X", $0) }.joined(separator: ":")

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        try await super.tearDown()
    }

    private func config(_ routes: [ProviderProfile] = [], main: Bool = true) -> AppConfig {
        let suite = "dsh.swapperguide.test.\(UUID().uuidString)"
        suites.append(suite)
        secrets = MemorySecretStore()
        let config = AppConfig(defaults: UserDefaults(suiteName: suite)!, secrets: secrets)
        config.providers = routes
        config.activeRoute = main ? routes.first?.routeID : nil
        return config
    }

    private func model(_ key: String, _ title: String, served: String, installed: Bool = true, running: Bool = false,
                       window: Int = 262_144) -> SwapperStatus.Model {
        SwapperStatus.Model(key: key, title: title, context: window, served_id: served, running: running, healthy: running,
                            installed: installed, perf: .init(decode: 58, estimate: false))
    }

    private func status(active: String?, job: SwapperStatus.Job? = nil, busy: Bool = false) -> SwapperStatus {
        SwapperStatus(active: active, busy: busy,
                      models: ["standard": model("standard", "Qwen3.8 27B", served: "Qwen3.8-27B", running: active == "standard",
                                                 window: 1_000_000),
                               "flash": model("flash", "Qwen3.8 Flash", served: "qwen3.8-flash", running: active == "flash",
                                              window: 524_288),
                               "big": model("big", "Big One", served: "big", installed: false)],
                      job: job, version: "2.0.0", platform: "nvidia-gb10", hostname: "spark-3f2a")
    }

    private func code() -> String {
        SwapperConnectionCode.encode([
            "v": 1, "name": "DGX Spark (spark-3f2a)", "hostname": "spark-3f2a", "platform": "nvidia-gb10",
            "swapper_url": "https://192.168.1.42:8999", "api_base": "https://192.168.1.42:11443/v1",
            "api_key": "vllm-local", "model": "Qwen3.8-27B", "context": 1_000_000, "fingerprint": fingerprint,
            "token": "sst_1a2b3c4d_tok", "user": "pat",
        ])
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testACodeSetsUpTheBoxAsThePrimaryWhenThereIsNone() async throws {
        let backend = FakeSwapperBackend()
        backend.checkResult = .success(status(active: "standard"))
        let c = config()
        let guide = SwapperGuideModel(backend: backend, config: c)
        XCTAssertEqual(guide.role, .primary, "nothing leads yet")
        XCTAssertFalse(guide.canAdvance)
        guide.codeText = "not a code"
        XCTAssertEqual(guide.codeProblem, SwapperConnectionCode.invalidMessage)
        guide.codeText = "\n" + code() + "\n"
        XCTAssertNil(guide.codeProblem)
        XCTAssertTrue(guide.canAdvance)

        guide.next()
        XCTAssertEqual(guide.page, .check)
        try await waitUntil("the check") { guide.status != nil }
        XCTAssertEqual(guide.connectedLine, "Connected to DGX Spark (spark-3f2a) — DGX Spark — serving Qwen3.8 27B (1M context)")
        XCTAssertEqual(backend.calls, ["check:https://192.168.1.42:8999"])

        guide.next()
        XCTAssertEqual(guide.page, .model)
        XCTAssertEqual(guide.selectedKey, "standard", "the model serving now is picked")
        XCTAssertFalse(guide.needsSwitch)
        guide.choose("big")
        XCTAssertEqual(guide.selectedKey, "standard", "a model that isn't installed can't be picked")

        guide.next()
        XCTAssertEqual(guide.page, .use)
        XCTAssertTrue(guide.isPrivate, "your own hardware is private")
        guide.next()
        XCTAssertEqual(guide.page, .done)
        try await waitUntil("the hello") { guide.hello != nil }

        let route = try XCTUnwrap(guide.saved)
        XCTAssertEqual(route.kind, .openAICompat)
        XCTAssertEqual(route.name, "DGX Spark (spark-3f2a)")
        XCTAssertEqual(route.baseURL, "https://192.168.1.42:11443/v1")
        XCTAssertEqual(route.model, "Qwen3.8-27B")
        XCTAssertEqual(route.pinnedCertificate, fingerprint)
        XCTAssertNil(route.contextWindow, "the window is automatic")
        XCTAssertNil(route.isPrivate, "private by its address, so nothing to store")
        XCTAssertTrue(route.isPrivateRoute)
        XCTAssertTrue(route.isEnabled)
        XCTAssertNil(route.apiKey, "the key isn't in the settings")
        XCTAssertEqual(c.apiKey(for: route), "vllm-local", "it is in the secure store")
        XCTAssertEqual(c.mainRoute?.routeID, route.routeID)
        let (box, secret, linkedRoute) = try XCTUnwrap(backend.registered.first)
        XCTAssertEqual(secret, "sst_1a2b3c4d_tok")
        XCTAssertEqual(box.auth, .token)
        XCTAssertEqual(box.apiBase, "https://192.168.1.42:11443/v1")
        XCTAssertEqual(box.version, "2.0.0")
        XCTAssertEqual(box.linkedRoutes, [route.routeID])
        XCTAssertEqual(linkedRoute.routeID, route.routeID)
        XCTAssertEqual(backend.hellos.first?.apiKey, "vllm-local", "the hello goes through with the key")
        XCTAssertEqual(guide.hello, "Hello from your own box!")
    }

    func testWithAPrimaryAlreadyItDefaultsToSubagentAndCanBeABackup() async throws {
        let existing = ProviderProfile(kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt")
        let c = config([existing])
        let backend = FakeSwapperBackend()
        backend.checkResult = .success(status(active: "standard"))
        let guide = SwapperGuideModel(backend: backend, config: c)
        XCTAssertEqual(guide.role, .subagent)
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.status != nil }
        guide.next()
        guide.next()
        guide.role = .backup
        guide.next()
        try await waitUntil("saved") { guide.saved != nil }
        let route = try XCTUnwrap(c.providers.first { $0.name == "DGX Spark (spark-3f2a)" })
        XCTAssertTrue(route.isBackup)
        XCTAssertFalse(route.isSubagentWorker)
        XCTAssertEqual(c.mainRoute?.name, "OpenAI", "the primary stays the primary")
        XCTAssertEqual(c.backupRoutes.map(\.name), ["DGX Spark (spark-3f2a)"])
    }

    func testPickingAnotherModelSwitchesTheBoxAndTheRouteUsesIt() async throws {
        let backend = FakeSwapperBackend()
        backend.checkResult = .success(status(active: "standard"))
        let running = SwapperStatus.Job(id: "j2", target: "flash", source: "standard", state: "running", error: nil,
                                        note: nil, started: Date().timeIntervalSince1970, finished: nil,
                                        steps: [.init(key: "load", label: "Loading weights", state: "running")])
        var done = running
        done.state = "done"
        backend.statuses = [status(active: nil, job: running, busy: true), status(active: "flash", job: done)]
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.pollInterval = 0.01
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.status != nil }
        guide.next()
        guide.choose("flash")
        XCTAssertTrue(guide.needsSwitch)
        XCTAssertFalse(guide.canAdvance, "\"Switch now\" or \"Keep\" first")
        guide.keepCurrent()
        XCTAssertEqual(guide.selectedKey, "standard")
        guide.choose("flash")
        guide.switchNow()
        XCTAssertTrue(guide.switching)
        try await waitUntil("the switch") { !guide.switching }
        XCTAssertNil(guide.switchError)
        XCTAssertEqual(guide.status?.active, "flash")
        XCTAssertFalse(guide.needsSwitch)
        XCTAssertTrue(backend.calls.contains("swap:flash"))
        guide.next()
        guide.next()
        try await waitUntil("saved") { guide.saved != nil }
        XCTAssertEqual(guide.saved?.model, "qwen3.8-flash", "the route names the model the box serves now")
    }

    func testAFailedSwitchSaysWhyAndKeepsTheModelThatServes() async throws {
        let backend = FakeSwapperBackend()
        backend.checkResult = .success(status(active: "standard"))
        let failed = SwapperStatus.Job(id: "j3", target: "flash", source: "standard", state: "failed",
                                       error: "out of memory", note: "The previous model is back.",
                                       started: 1, finished: 2, steps: [])
        backend.statuses = [status(active: "standard", job: failed)]
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.pollInterval = 0.01
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.status != nil }
        guide.next()
        guide.choose("flash")
        guide.switchNow()
        try await waitUntil("the switch") { !guide.switching }
        XCTAssertEqual(guide.switchError, "Switching failed: out of memory. The previous model is back.")
        XCTAssertEqual(guide.selectedKey, "standard")
    }

    func testAModelTheBoxDoesNotHaveCanBeInstalledThenSwitchedTo() async throws {
        let backend = FakeSwapperBackend()
        var before = status(active: "standard")
        before.models["big"]?.install = .init(size_gb: 60, time: "15–30 minutes")
        backend.checkResult = .success(before)
        let job = SwapperStatus.Job(id: "i1", target: "install:model:big", state: "running", started: Date().timeIntervalSince1970,
                                    steps: [.init(key: "fetch", label: "Downloading", state: "running")],
                                    log: [.init(t: 1, m: "fetching weights 40%")])
        var finished = job
        finished.state = "done"
        backend.installResult = .success(job)
        backend.installJobs = [job, finished]
        var after = before
        after.models["big"]?.installed = true
        backend.statuses = [after]
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.pollInterval = 0.01
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.status != nil }
        guide.next()
        XCTAssertEqual(guide.status?.models["big"]?.install?.summary, "60 GB · 15–30 minutes")
        guide.install("big")
        XCTAssertEqual(guide.installing, "big")
        XCTAssertFalse(guide.canAdvance, "not while it installs")
        XCTAssertNotNil(guide.installProgress())
        try await waitUntil("the install") { guide.installing == nil }
        XCTAssertNil(guide.installError)
        XCTAssertTrue(guide.installed.contains("big"))
        XCTAssertEqual(guide.selectedKey, "big", "the new model is picked, ready to switch to")
        XCTAssertTrue(guide.needsSwitch)
        XCTAssertEqual(backend.calls.filter { $0.hasPrefix("install") }, ["install:big", "installJob", "installJob"])
    }

    func testAnotherInstallRunningIsSaidPlainly() async throws {
        let backend = FakeSwapperBackend()
        var before = status(active: "standard")
        before.models["big"]?.install = .init(size_gb: 60)
        backend.checkResult = .success(before)
        backend.installResult = .failure(SwapperError.installBusy("An install is already in progress."))
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.status != nil }
        guide.next()
        guide.install("big")
        try await waitUntil("the refusal") { guide.installing == nil }
        XCTAssertEqual(guide.installError,
                       "Another install is already running on DGX Spark (spark-3f2a). Wait for it to finish, then try again.")
    }

    func testASwitchToAModelThatIsNotInstalledSaysWhereToInstallIt() async throws {
        let backend = FakeSwapperBackend()
        backend.checkResult = .success(status(active: "standard"))
        backend.swapError = SwapperError.notInstalled
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.status != nil }
        guide.next()
        guide.choose("flash")
        guide.switchNow()
        try await waitUntil("the refusal") { !guide.switching }
        XCTAssertEqual(guide.switchError,
                       "That model isn't installed on DGX Spark (spark-3f2a) yet — install it from Settings ▸ Model Servers.")
    }

    func testACertificateMismatchStopsTheGuideWithTheWarning() async throws {
        let backend = FakeSwapperBackend()
        backend.checkResult = .failure(SwapperError.certificateMismatch(url: "https://192.168.1.42:8999", presented: "BB"))
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.checkError != nil }
        XCTAssertEqual(guide.checkError,
                       "The Swapper at https://192.168.1.42:8999 showed a different security certificate than the code expects. If you reinstalled the Swapper, copy a fresh code. Otherwise don't continue — something may be intercepting the connection.")
        XCTAssertFalse(guide.canAdvance)
    }

    func testAnUnreachableBoxIsNamedWithAHint() async throws {
        let backend = FakeSwapperBackend()
        backend.checkResult = .failure(SwapperError.transport("The request timed out."))
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.checkError != nil }
        XCTAssertEqual(guide.checkError,
                       "Couldn't reach the Swapper at https://192.168.1.42:8999. The box may be switched off, or this Mac may be on another network.")
    }

    func testAnAddressAndLoginAsksToTrustTheCertificateFirst() async throws {
        let backend = FakeSwapperBackend()
        let connection = SwapperConnection(name: "DGX Spark (spark.local)", url: "https://spark.local:8999",
                                           auth: .login(username: "pat"), pinnedFingerprint: fingerprint)
        backend.loginOutcomes = [.needsTrust(fingerprint: fingerprint),
                                 .connected(connection, secret: "pw", connect: nil,
                                            credentials: SwapperCredentials(apiKey: "k", apiBase: "https://spark.local:11443/v1", model: nil))]
        backend.statuses = [status(active: "standard")]
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.usesLogin = true
        XCTAssertFalse(guide.canAdvance)
        guide.address = "spark.local"
        guide.username = "pat"
        guide.password = "pw"
        XCTAssertTrue(guide.canAdvance)
        guide.next()
        try await waitUntil("the certificate question") { guide.untrustedFingerprint != nil }
        XCTAssertNil(guide.status)
        guide.trustCertificate()
        try await waitUntil("signed in") { guide.status != nil }
        XCTAssertEqual(backend.calls.filter { $0.hasPrefix("login") }, ["login:spark.local:pat:-", "login:spark.local:pat:\(fingerprint)"],
                       "the password goes only to the certificate the user trusted")
        XCTAssertEqual(guide.apiBase, "https://spark.local:11443/v1")
        XCTAssertEqual(guide.apiKey, "k")
    }

    // MARK: Running it again

    /// The code path to the end, leaving the role as it comes unless `role` says otherwise.
    private func runCode(_ c: AppConfig, _ backend: FakeSwapperBackend, role: ModelRole? = nil) async throws -> SwapperGuideModel {
        let guide = SwapperGuideModel(backend: backend, config: c)
        guide.codeText = code()
        guide.next()
        try await waitUntil("the check") { guide.status != nil }
        guide.next()
        guide.next()
        if let role { guide.role = role }
        guide.next()
        try await waitUntil("saved") { guide.saved != nil }
        return guide
    }

    func testRunningItAgainForTheSameBoxKeepsTheRoutesOwnSettings() async throws {
        var mine = ProviderProfile(kind: .openAICompat, name: "DGX Spark (spark-3f2a)", baseURL: "https://192.168.1.40:11443/v1",
                                   model: "Qwen3.8-27B", temperature: 0.2, contextWindow: 131_072,
                                   customHeaders: ["X-Team": "a"], reasoningEffort: "high", subagentParallel: 3, backup: true,
                                   interactiveOnly: true)
        mine.isPrivate = false
        let lead = ProviderProfile(kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt")
        let c = config([lead, mine])
        c.setAPIKey("old-key", for: mine)
        let backend = FakeSwapperBackend()
        backend.checkResult = .success(status(active: "standard"))
        // The box the route was made for, at the same Swapper address.
        backend.known = [SwapperConnection(name: "DGX Spark (spark-3f2a)", url: "https://192.168.1.42:8999", auth: .token,
                                           linkedRoutes: [mine.routeID])]
        _ = try await runCode(c, backend)

        XCTAssertEqual(c.providers.count, 2, "updated, not added")
        let route = try XCTUnwrap(c.providers.first { $0.routeID == mine.routeID })
        XCTAssertEqual(route.baseURL, "https://192.168.1.42:11443/v1", "the guide's address…")
        XCTAssertEqual(route.pinnedCertificate, fingerprint, "…certificate…")
        XCTAssertEqual(c.apiKey(for: route), "vllm-local", "…and key")
        XCTAssertEqual(route.contextWindow, 131_072)
        XCTAssertEqual(route.reasoningEffort, "high")
        XCTAssertEqual(route.temperature, 0.2)
        XCTAssertEqual(route.customHeaders, ["X-Team": "a"])
        XCTAssertEqual(route.subagentParallel, 3)
        XCTAssertEqual(route.interactiveOnly, true)
        XCTAssertEqual(route.isPrivate, false, "the user's own choice, untouched")
        XCTAssertTrue(route.isBackup, "a role the user didn't change stays")
        XCTAssertFalse(route.isSubagentWorker)
        XCTAssertEqual(c.mainRoute?.name, "OpenAI")
    }

    func testAnotherBoxWithTheSameNameAndModelGetsARouteOfItsOwn() async throws {
        let first = ProviderProfile(kind: .openAICompat, name: "DGX Spark (spark-3f2a)", baseURL: "https://10.0.0.7:11443/v1",
                                    model: "Qwen3.8-27B", contextWindow: 65_536)
        let c = config([first])
        c.setAPIKey("first-key", for: first)
        let backend = FakeSwapperBackend()
        backend.checkResult = .success(status(active: "standard"))
        backend.known = [SwapperConnection(name: "DGX Spark (spark-3f2a)", url: "https://10.0.0.7:8999", auth: .token,
                                           linkedRoutes: [first.routeID])]
        let guide = try await runCode(c, backend)

        let saved = try XCTUnwrap(guide.saved)
        XCTAssertEqual(saved.name, "DGX Spark (spark-3f2a) 2")
        XCTAssertEqual(c.providers.count, 2)
        let untouched = try XCTUnwrap(c.providers.first { $0.routeID == first.routeID })
        XCTAssertEqual(untouched.baseURL, "https://10.0.0.7:11443/v1")
        XCTAssertEqual(untouched.contextWindow, 65_536)
        XCTAssertEqual(c.apiKey(for: untouched), "first-key")
        XCTAssertEqual(c.apiKey(for: saved), "vllm-local")
        XCTAssertEqual(backend.registered.last?.0.linkedRoutes, [saved.routeID], "the new box is linked to its own route only")
    }

    func testAnotherAddressOrLoginStartsTheCheckOver() async throws {
        let backend = FakeSwapperBackend()
        let boxA = SwapperConnection(name: "DGX Spark (a)", url: "https://a.local:8999", auth: .login(username: "pat"),
                                     pinnedFingerprint: fingerprint)
        let signedIn = SwapperConnect.LoginOutcome.connected(
            boxA, secret: "pw", connect: nil, credentials: SwapperCredentials(apiKey: "k", apiBase: "https://a.local:11443/v1", model: nil))
        backend.loginOutcomes = [signedIn, signedIn]
        backend.statuses = [status(active: "standard")]
        let guide = SwapperGuideModel(backend: backend, config: config())
        guide.usesLogin = true
        guide.address = "a.local"
        guide.username = "pat"
        guide.password = "pw"
        guide.next()
        try await waitUntil("signed in") { guide.status != nil }
        XCTAssertEqual(guide.boxName, "DGX Spark (a)")
        guide.back()
        guide.address = "b.local"
        XCTAssertNil(guide.status, "box A's check doesn't carry over to box B")
        XCTAssertNil(guide.route())
        guide.address = "a.local"
        guide.next()
        try await waitUntil("signed in again") { guide.status != nil }
        guide.password = "other"
        XCTAssertNil(guide.status, "nor to another password")
    }

    func testTheAppTokenIsMadeOnlyWhenTheGuideSaves() async throws {
        let backend = FakeSwapperBackend()
        let box = SwapperConnection(name: "DGX Spark (spark.local)", url: "https://spark.local:8999", auth: .login(username: "pat"),
                                    pinnedFingerprint: fingerprint, apiBase: "https://spark.local:11443/v1")
        backend.loginOutcomes = [.connected(box, secret: "pw", connect: nil,
                                            credentials: SwapperCredentials(apiKey: "k", apiBase: "https://spark.local:11443/v1", model: nil))]
        backend.statuses = [status(active: "standard")]
        let c = config()
        let guide = SwapperGuideModel(backend: backend, config: c)
        guide.usesLogin = true
        guide.address = "spark.local"
        guide.username = "pat"
        guide.password = "pw"
        guide.next()
        try await waitUntil("signed in") { guide.status != nil }
        guide.next()
        guide.next()
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("keep") }, "nothing made on the box while the guide runs")

        backend.keepError = SwapperError.transport("The request timed out.")
        guide.next()
        try await waitUntil("the error") { guide.saveError != nil }
        XCTAssertNil(guide.saved)
        XCTAssertTrue(backend.registered.isEmpty)
        backend.keepError = nil
        guide.saveAndSayHello()
        try await waitUntil("saved") { guide.saved != nil }
        XCTAssertEqual(backend.calls.filter { $0.hasPrefix("keep") }, ["keep:pw", "keep:pw"])
        let (kept, secret, _) = try XCTUnwrap(backend.registered.first)
        XCTAssertEqual(secret, "sst_9f8e7d6c_kept", "the token, not the password")
        XCTAssertEqual(kept.auth, .token)
    }
}
