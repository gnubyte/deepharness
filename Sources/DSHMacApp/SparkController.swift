import Foundation
import Observation
import Security
import DSHCore

/// Drives the Spark Swapper from the app: which model the Spark is serving,
/// switching it, and following the switch in every chat.
///
/// Address, username and the pinned certificate fingerprint live in
/// UserDefaults; the password lives in the Keychain.
@MainActor
@Observable
final class SparkController {
    private let defaults: UserDefaults
    private weak var transport: AppTransport?
    private let config: AppConfig

    private enum Keys {
        static let url = "spark.swapper.url"
        static let user = "spark.swapper.user"
        static let pin = "spark.swapper.pin"
    }
    private static let keychainService = "DSHMac.sparkSwapper"

    var url: String { didSet { defaults.set(url, forKey: Keys.url); client = nil } }
    var username: String { didSet { defaults.set(username, forKey: Keys.user); client = nil } }
    var pinnedFingerprint: String? { didSet { defaults.set(pinnedFingerprint, forKey: Keys.pin); client = nil } }

    private(set) var status: SwapperStatus?
    private(set) var lastError: String?
    /// A certificate the user hasn't approved yet (shown in Settings ▸ Spark).
    private(set) var untrustedFingerprint: String?
    private(set) var refreshing = false
    /// The model the user picked and is being asked to confirm.
    var confirmTarget: SwapperStatus.Model?

    @ObservationIgnored private var client: SparkSwapperClient?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchedJob: String?

    init(config: AppConfig, transport: AppTransport, defaults: UserDefaults = .standard) {
        self.config = config
        self.transport = transport
        self.defaults = defaults
        url = defaults.string(forKey: Keys.url) ?? ""
        username = defaults.string(forKey: Keys.user) ?? ""
        pinnedFingerprint = defaults.string(forKey: Keys.pin)
        if url.isEmpty, let base = config.activeProvider?.baseURL, config.activeProvider?.isSelfHosted == true,
           let guess = SparkSwapperClient.defaultURL(forModelServer: base) {
            url = guess
        }
    }

    // MARK: Configuration

    var isConfigured: Bool { !url.isEmpty && !username.isEmpty && !password.isEmpty }
    var isSwitching: Bool { status?.isSwitching ?? false }

    var password: String {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: "login",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return "" }
            return String(decoding: d, as: UTF8.self)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: Self.keychainService,
                                       kSecAttrAccount as String: "login"]
            SecItemDelete(base as CFDictionary)
            if !newValue.isEmpty, let d = newValue.data(using: .utf8) {
                var add = base
                add[kSecValueData as String] = d
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(add as CFDictionary, nil)
            }
            client = nil
        }
    }

    private func makeClient() throws -> SparkSwapperClient {
        if let client { return client }
        guard isConfigured, let u = URL(string: url.trimmingCharacters(in: .whitespaces)) else {
            throw SwapperError.notConfigured
        }
        let c = SparkSwapperClient(baseURL: u, username: username, password: password,
                                   pinnedFingerprint: pinnedFingerprint)
        client = c
        return c
    }

    /// Approve the certificate the server presented.
    func trustPresentedCertificate() {
        guard let fp = untrustedFingerprint else { return }
        pinnedFingerprint = fp
        untrustedFingerprint = nil
        lastError = nil
        Task { await refresh() }
    }

    // MARK: Status

    func refresh() async {
        guard isConfigured else { status = nil; return }
        refreshing = true
        defer { refreshing = false }
        do {
            let s = try await makeClient().status()
            let wasRunning = status?.job?.isRunning ?? false
            status = s
            lastError = nil
            untrustedFingerprint = nil
            if let job = s.job, !job.isRunning, (wasRunning || watchedJob == job.id) {
                finished(job, status: s)
            }
            if s.isSwitching { schedulePolling() }
        } catch let e as SwapperError {
            if case .untrustedCertificate(let fp) = e { untrustedFingerprint = fp }
            lastError = e.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Poll quickly while a swap runs, slowly otherwise.
    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let fast = self.isSwitching
                try? await Task.sleep(nanoseconds: (fast ? 2 : 30) * 1_000_000_000)
            }
        }
    }

    private func schedulePolling() { startMonitoring() }

    // MARK: Switching

    /// Ask to switch (the UI confirms via `confirmTarget`).
    func request(_ model: SwapperStatus.Model) {
        guard model.key != status?.active else { return }
        confirmTarget = model
    }

    /// Switch now. Returns an error message, or nil when the swap started.
    @discardableResult
    func swap(to key: String) async -> String? {
        do {
            try await makeClient().swap(to: key)
            await refresh()
            watchedJob = status?.job?.id
            startMonitoring()
            let title = status?.models[key]?.title ?? key
            transport?.broadcast("Switching the Spark to **\(title)**… chats will pick it up automatically when it is ready.")
            return nil
        } catch let e as SwapperError {
            lastError = e.errorDescription
            return e.errorDescription
        } catch {
            lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

    private func finished(_ job: SwapperStatus.Job, status s: SwapperStatus) {
        watchedJob = nil
        transport?.resetRouteCache()
        let title = s.models[job.target]?.title ?? job.target
        if job.state == "done", let m = s.models[job.target] {
            let ctx = (m.served_context ?? m.context).formatted()
            transport?.broadcast("✅ The Spark is now serving **\(title)** (`\(m.served_id)`, \(ctx)-token context).")
        } else if job.state == "failed" {
            transport?.broadcast("⚠️ Switching the Spark to \(title) failed: \(job.error ?? "unknown error"). \(job.note ?? "")", error: true)
        }
    }

    /// `/swap [model]`: list, or switch.
    func handleCommand(_ arg: String?, in vm: SessionVM) async {
        guard isConfigured else {
            vm.note(SwapperError.notConfigured.errorDescription ?? "", role: .error)
            return
        }
        await refresh()
        guard let s = status else {
            vm.note(lastError ?? "Couldn't read the Spark's status.", role: .error)
            return
        }
        guard let arg, !arg.isEmpty else {
            let lines = s.ordered.map { m -> String in
                let mark = m.key == s.active ? "● serving" : (m.running ? "◌ loading" : "○")
                return "\(mark)  **\(m.title)** — `\(m.key)` · \(m.context.formatted()) ctx · \(m.engine ?? "")"
            }
            vm.note("Spark models:\n" + lines.joined(separator: "\n")
                    + "\nSwitch with `/swap <name>` or the model menu under the composer.")
            return
        }
        guard let key = s.resolve(arg), let target = s.models[key] else {
            vm.note("No Spark model matches “\(arg)”. Options: \(s.ordered.map(\.key).joined(separator: ", ")).", role: .error)
            return
        }
        if key == s.active {
            vm.note("The Spark is already serving \(target.title).")
            return
        }
        if s.isSwitching {
            vm.note("The Spark is already switching models; wait for it to finish.", role: .error)
            return
        }
        if let err = await swap(to: key) { vm.note(err, role: .error) }
    }

    /// Human-readable progress line for the banner.
    var progressLine: String? {
        guard let job = status?.job, job.isRunning else { return nil }
        let title = status?.models[job.target]?.title ?? job.target
        let step = job.currentStep?.label ?? "Working"
        let elapsed = Int(Date().timeIntervalSince1970 - job.started)
        return "Switching the Spark to \(title) · \(step) · \(elapsed / 60)m \(String(format: "%02d", elapsed % 60))s"
    }
}
