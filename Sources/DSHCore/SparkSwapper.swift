import Foundation
import Security

// MARK: - Spark Swapper client
//
// Talks to the Spark Swapper web service (https://<box>:8999) that stops one
// model server on a DGX Spark — or, from Swapper 2.0, an AMD Strix Halo box —
// and starts another. Same API the web page uses: GET /api/status, POST
// /api/swap, and so on. It signs in one of two ways:
//   * an app token (Swapper 2.0): `Authorization: Bearer sst_…` on every
//     request, from a connection code the user pasted — no password stored;
//   * a username and password (any Swapper): POST /api/login, cookie session.
//
// The service uses a self-signed certificate. If the system doesn't trust it,
// the client pins the leaf certificate's SHA-256 fingerprint the user approved
// once (trust on first use) or that the connection code carried, and refuses
// anything else.

public struct SwapperStatus: Decodable, Sendable, Equatable {
    /// Published speeds in tokens/second: `decode` is one request on its own, `decode_concurrent` the total
    /// across `concurrency` requests. `estimate` means nobody measured it and the figure is a rough guess.
    public struct Perf: Decodable, Sendable, Equatable {
        public var decode: Double?
        public var decode_concurrent: Double?
        public var concurrency: Int?
        public var prefill: Double?
        public var source: String?
        public var estimate: Bool?

        public init(decode: Double? = nil, decode_concurrent: Double? = nil, concurrency: Int? = nil,
                    prefill: Double? = nil, source: String? = nil, estimate: Bool? = nil) {
            self.decode = decode
            self.decode_concurrent = decode_concurrent
            self.concurrency = concurrency
            self.prefill = prefill
            self.source = source
            self.estimate = estimate
        }
    }

    /// The decode speed the Swapper itself measured on this box the last time it loaded the model.
    public struct Measured: Decodable, Sendable, Equatable {
        public var decode: Double?
        public var at: Double?

        public init(decode: Double? = nil, at: Double? = nil) {
            self.decode = decode
            self.at = at
        }
    }

    public struct Model: Decodable, Sendable, Equatable, Identifiable {
        public var key: String
        public var title: String
        public var tagline: String?
        public var engine: String?
        public var context: Int
        public var served_context: Int?
        public var served_id: String
        public var vision: Bool?
        public var running: Bool
        public var healthy: Bool
        public var order: Int?
        // Swapper 2.0 (absent from 1.x, which is fine):
        public var installed: Bool?
        public var platform: String?
        public var perf: Perf?
        public var measured: Measured?
        public var family: String?
        /// What installing it takes ("60 GB", "15–30 minutes: …"); nil when it can't be installed from the Swapper.
        public var install: Install?
        /// How long switching to it takes ("about 11 minutes").
        public var eta: String?
        public var id: String { key }

        public struct Install: Decodable, Sendable, Equatable {
            public var size_gb: Double?
            public var time: String?

            public init(size_gb: Double? = nil, time: String? = nil) {
                self.size_gb = size_gb
                self.time = time
            }

            /// "60 GB · 15–30 minutes: pulls or builds the image…"
            public var summary: String? {
                var parts: [String] = []
                if let size_gb, size_gb > 0 {
                    parts.append(size_gb.rounded() == size_gb ? "\(Int(size_gb)) GB" : String(format: "%.1f GB", size_gb))
                }
                if let time, !time.isEmpty { parts.append(time) }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
        }

        public init(key: String, title: String, tagline: String? = nil, engine: String? = nil, context: Int,
                    served_context: Int? = nil, served_id: String, vision: Bool? = nil, running: Bool = false,
                    healthy: Bool = false, order: Int? = nil, installed: Bool? = nil, platform: String? = nil,
                    perf: Perf? = nil, measured: Measured? = nil, family: String? = nil, install: Install? = nil,
                    eta: String? = nil) {
            self.key = key
            self.title = title
            self.tagline = tagline
            self.engine = engine
            self.context = context
            self.served_context = served_context
            self.served_id = served_id
            self.vision = vision
            self.running = running
            self.healthy = healthy
            self.order = order
            self.installed = installed
            self.platform = platform
            self.perf = perf
            self.measured = measured
            self.family = family
            self.install = install
            self.eta = eta
        }

        /// In the catalog *and* on the box. (A 1.x Swapper only lists what it has.) Only installed models can
        /// be switched to — the others are installed on the Swapper's Models page.
        public var isInstalled: Bool { installed ?? true }

        /// The window it serves (`served_context` when the serve narrows or stretches it).
        public var window: Int { served_context ?? context }

        /// How fast it answers, for a menu: what the Swapper measured on this box ("27 tok/s measured here"),
        /// else the published figure ("~58 tok/s"), else nothing. A rough estimate shows only where there is
        /// room, and is never passed off as a measurement.
        public func speedText(roomForEstimate: Bool = false) -> String? {
            if let measured = measured?.decode, measured > 0 { return "\(Int(measured.rounded())) tok/s measured here" }
            guard let perf, let decode = perf.decode, decode > 0 else { return nil }
            if perf.estimate == true {
                return roomForEstimate ? "≈\(Int(decode.rounded())) tok/s (estimate)" : nil
            }
            return "~\(Int(decode.rounded())) tok/s"
        }

        /// How long switching to it takes, for a sentence ("takes about 11 minutes"): the Swapper's own figure, else
        /// a rough one.
        public var switchDuration: String {
            if let eta, !eta.trimmingCharacters(in: .whitespaces).isEmpty { return eta }
            return key.contains("flash") || title.lowercased().contains("flash") ? "about 11 minutes" : "a few minutes"
        }
    }

    public struct Step: Decodable, Sendable, Equatable {
        public var key: String
        public var label: String
        public var state: String

        public init(key: String, label: String, state: String) {
            self.key = key
            self.label = label
            self.state = state
        }
    }

    /// One line of a job's log: seconds since the epoch, and the text.
    public struct LogLine: Decodable, Sendable, Equatable {
        public var t: Double
        public var m: String

        public init(t: Double, m: String) {
            self.t = t
            self.m = m
        }
    }

    /// A swap — or, from /api/provisioning/job, an install (target "install:model:<key>").
    public struct Job: Decodable, Sendable, Equatable {
        public var id: String
        public var target: String
        public var source: String?
        public var state: String          // running | done | failed
        public var error: String?
        public var note: String?
        public var started: Double
        public var finished: Double?
        public var steps: [Step]
        public var log: [LogLine]?

        public init(id: String, target: String, source: String? = nil, state: String, error: String? = nil,
                    note: String? = nil, started: Double, finished: Double? = nil, steps: [Step] = [], log: [LogLine]? = nil) {
            self.id = id
            self.target = target
            self.source = source
            self.state = state
            self.error = error
            self.note = note
            self.started = started
            self.finished = finished
            self.steps = steps
            self.log = log
        }

        public var isRunning: Bool { state == "running" }
        public var currentStep: Step? { steps.first { $0.state == "running" } ?? steps.last { $0.state == "failed" } }
        /// The newest line of its log, for a progress line.
        public var lastLogLine: String? {
            log?.last.map { $0.m.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        /// The model an install job is for ("install:model:flash" → "flash"); nil for anything else.
        public var installingModel: String? {
            target.hasPrefix("install:model:") ? String(target.dropFirst("install:model:".count)) : nil
        }
    }

    public var active: String?
    public var loading: String?
    public var busy: Bool
    public var models: [String: Model]
    public var job: Job?
    public var openclaw_primary: String?
    // Swapper 2.0:
    public var version: String?
    public var platform: String?
    public var hostname: String?
    /// The install running now (or finished in the last few minutes).
    public var install_job: Job?

    public init(active: String? = nil, loading: String? = nil, busy: Bool = false, models: [String: Model] = [:],
                job: Job? = nil, openclaw_primary: String? = nil, version: String? = nil, platform: String? = nil,
                hostname: String? = nil, install_job: Job? = nil) {
        self.active = active
        self.loading = loading
        self.busy = busy
        self.models = models
        self.job = job
        self.openclaw_primary = openclaw_primary
        self.version = version
        self.platform = platform
        self.hostname = hostname
        self.install_job = install_job
    }

    /// Models in display order.
    public var ordered: [Model] {
        models.values.sorted { ($0.order ?? 9, $0.title) < ($1.order ?? 9, $1.title) }
    }

    /// The models a switch can go to, in display order.
    public var installedModels: [Model] { ordered.filter(\.isInstalled) }

    public var activeModel: Model? { active.flatMap { models[$0] } }
    public var isSwitching: Bool { busy || (job?.isRunning ?? false) }

    /// Match user input ("flash", "27b", "standard", a served id) to a model key.
    public func resolve(_ query: String) -> String? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if models[q] != nil { return q }
        let hits = models.values.filter {
            $0.served_id.lowercased() == q || $0.title.lowercased() == q
                || $0.key.lowercased().contains(q) || $0.title.lowercased().contains(q)
                || $0.served_id.lowercased().contains(q)
        }
        return hits.count == 1 ? hits[0].key : nil
    }
}

/// What kind of box a Swapper runs on.
public enum SwapperPlatform {
    public static let dgxSpark = "nvidia-gb10"
    public static let strixHalo = "amd-strix-halo"

    /// "DGX Spark", "Strix Halo". A Swapper older than 2.0 doesn't say, and only ran on a DGX Spark.
    public static func displayName(_ platform: String?) -> String {
        switch platform {
        case nil, dgxSpark?: "DGX Spark"
        case strixHalo?: "Strix Halo"
        default: "Model server"
        }
    }
}

/// GET /api/connect (Swapper 2.0): everything an app needs to use the box — and, inside a connection code,
/// the app token and user as well.
public struct SwapperConnectInfo: Codable, Sendable, Equatable {
    public var name: String?
    public var hostname: String?
    public var platform: String?
    public var version: String?
    public var swapperURL: String
    public var apiBase: String
    public var apiKey: String?
    /// What is serving now (nil when nothing is).
    public var model: String?
    public var context: Int?
    /// SHA-256 of the TLS certificate both the Swapper and the model front present.
    public var fingerprint: String

    enum CodingKeys: String, CodingKey {
        case name, hostname, platform, version, model, context, fingerprint
        case swapperURL = "swapper_url", apiBase = "api_base", apiKey = "api_key"
    }

    public init(name: String? = nil, hostname: String? = nil, platform: String? = nil, version: String? = nil,
                swapperURL: String, apiBase: String, apiKey: String? = nil, model: String? = nil, context: Int? = nil,
                fingerprint: String) {
        self.name = name
        self.hostname = hostname
        self.platform = platform
        self.version = version
        self.swapperURL = swapperURL
        self.apiBase = apiBase
        self.apiKey = apiKey
        self.model = model
        self.context = context
        self.fingerprint = fingerprint
    }

    /// "DGX Spark (spark-3f2a)" — the box's own name, or one made from its platform and host.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let host = hostname ?? URL(string: swapperURL)?.host ?? "Swapper"
        return "\(SwapperPlatform.displayName(platform)) (\(host))"
    }
}

/// GET /api/session: whether the first admin exists yet, who we are, and (2.0) what the box is.
public struct SwapperSessionInfo: Decodable, Sendable, Equatable {
    public var setup_needed: Bool?
    public var user: String?
    public var role: String?
    public var demo: Bool?
    public var version: String?
    public var platform: String?
    public var hostname: String?
}

/// POST /api/tokens/create: a new app token, its connection code, and the connect details.
public struct SwapperTokenGrant: Decodable, Sendable, Equatable {
    public var id: String
    public var token: String
    public var code: String?
    public var connect: SwapperConnectInfo?
}

/// GET /api/credentials: the model API's key and address (any Swapper version).
public struct SwapperCredentials: Sendable, Equatable {
    public var apiKey: String?
    public var apiBase: String?
    public var model: String?

    public init(apiKey: String? = nil, apiBase: String? = nil, model: String? = nil) {
        self.apiKey = apiKey
        self.apiBase = apiBase
        self.model = model
    }
}

public enum SwapperError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case untrustedCertificate(fingerprint: String)
    /// The certificate presented isn't the one a connection code names (`pinOnly` checks).
    case certificateMismatch(url: String, presented: String)
    case badLogin(String)
    /// The app token was revoked, or the Swapper was reset.
    case revoked
    /// The Swapper is older than the endpoint (e.g. no app tokens before 2.0).
    case unsupported(String)
    /// A switch to a model the box hasn't installed yet.
    case notInstalled
    /// Another install is running on the box (one at a time).
    case installBusy(String)
    case server(Int, String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No Spark Swapper is set up. Add one in Settings ▸ Model Servers."
        case .untrustedCertificate(let fp): "The Spark Swapper's certificate isn't trusted yet (SHA-256 \(fp.prefix(23))…). Approve it in Settings ▸ Model Servers."
        case .certificateMismatch(let url, _):
            "The Swapper at \(url) showed a different security certificate than the code expects. If you reinstalled the Swapper, copy a fresh code. Otherwise don't continue — something may be intercepting the connection."
        case .badLogin(let m): "Spark Swapper login failed: \(m)"
        case .revoked: "The Swapper no longer accepts this app's connection (it was revoked or the Swapper was reset). Paste a new connection code."
        case .unsupported(let what): "This Swapper is older than \(what). Update it, or connect with an address and login."
        case .notInstalled: "That model isn't installed on the box yet — install it from Settings ▸ Model Servers."
        case .installBusy(let m): "Another install is already running on the box (\(m)). Wait for it to finish, then try again."
        case .server(let code, let m): "Spark Swapper replied \(code): \(m)"
        case .transport(let m): "Couldn't reach the Spark Swapper: \(m)"
        }
    }
}

/// How the client signs in to the Swapper.
public enum SwapperAuth: Sendable, Equatable {
    /// An app token (Swapper 2.0): sent as `Authorization: Bearer …`; there is no login.
    case token(String)
    /// The web page's username and password: POST /api/login, then a cookie session.
    case login(username: String, password: String)
}

public final class SparkSwapperClient: @unchecked Sendable {
    public let baseURL: URL
    public let auth: SwapperAuth
    private let delegate: PinningDelegate
    private let session: URLSession
    private var loggedIn = false
    private let lock = NSLock()

    /// Test hook: URLProtocol stubs the client's session routes through.
    nonisolated(unsafe) static var protocolClassesForTesting: [AnyClass]?

    public init(baseURL: URL, auth: SwapperAuth, pinnedFingerprint: String?, pinMode: PinningMode = .systemThenPin) {
        self.baseURL = baseURL
        self.auth = auth
        self.delegate = PinningDelegate(pinned: pinnedFingerprint, mode: pinMode)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        if let stubs = Self.protocolClassesForTesting { cfg.protocolClasses = stubs + (cfg.protocolClasses ?? []) }
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    public convenience init(baseURL: URL, username: String, password: String, pinnedFingerprint: String?) {
        self.init(baseURL: baseURL, auth: .login(username: username, password: password), pinnedFingerprint: pinnedFingerprint)
    }

    deinit { session.invalidateAndCancel() }

    /// A reasonable swapper address for a model server URL: same host, port 8999.
    public static func defaultURL(forModelServer base: String) -> String? {
        guard let host = URL(string: base)?.host, !host.isEmpty else { return nil }
        return "https://\(host):8999"
    }

    /// What someone typed for the Swapper's address ("192.168.1.42", "spark.local:8999", "https://spark:8999/")
    /// as the address to call: https, port 8999 unless one is given, no path.
    public static func normalizedURL(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        components.scheme = "https"
        if components.port == nil { components.port = 8999 }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// "https://192.168.1.42:8999" — what a browser on the Swapper's own page sends as its Origin.
    static func origin(_ url: URL) -> String {
        var text = "\(url.scheme ?? "https")://\(url.host ?? "")"
        if let port = url.port { text += ":\(port)" }
        return text
    }

    private func request(_ path: String, body: [String: Any]? = nil, sendAuth: Bool = true) async throws -> (Int, Data) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.setValue("1", forHTTPHeaderField: "X-Swapper")
        req.setValue(DSHIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if sendAuth, case .token(let token) = auth {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // The service refuses a POST whose Origin isn't its own address.
            req.setValue(Self.origin(baseURL), forHTTPHeaderField: "Origin")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let e as URLError where e.code == .cancelled || PinningDelegate.certificateFailures.contains(e.code) {
            if let fp = delegate.seenFingerprint, !CertificatePin.matches(fp, delegate.pinned) {
                if delegate.mode == .pinOnly {
                    throw SwapperError.certificateMismatch(url: Self.origin(baseURL), presented: fp)
                }
                throw SwapperError.untrustedCertificate(fingerprint: fp)
            }
            throw SwapperError.transport(e.localizedDescription)
        } catch {
            throw SwapperError.transport(error.localizedDescription)
        }
    }

    private static func message(_ data: Data) -> String {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private var isLoggedIn: Bool { lock.withLock { loggedIn } }
    private func setLoggedIn(_ v: Bool) { lock.withLock { loggedIn = v } }

    /// POST /api/login with the username and password. (Nothing to do with an app token.)
    public func login() async throws {
        guard case .login(let username, let password) = auth else { return }
        let (code, data) = try await request("api/login", body: ["username": username, "password": password])
        guard code == 200 else { throw SwapperError.badLogin(Self.message(data)) }
        setLoggedIn(true)
    }

    /// Call `path` signed in: with the token, or logging in first (or again, after a 401). The reply as it came.
    private func signedIn(_ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        var (code, data): (Int, Data)
        switch auth {
        case .token:
            (code, data) = try await request(path, body: body)
            if code == 401 { throw SwapperError.revoked }
        case .login:
            if !isLoggedIn { try await login() }
            (code, data) = try await request(path, body: body)
            if code == 401 {
                try await login()
                (code, data) = try await request(path, body: body)
            }
        }
        return (code, data)
    }

    /// Call `path` signed in; anything but a 2xx is an error.
    private func authed(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        let (code, data) = try await signedIn(path, body: body)
        guard (200...299).contains(code) else { throw SwapperError.server(code, Self.message(data)) }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SwapperError.transport("unexpected \(what) payload (\(error.localizedDescription))")
        }
    }

    public func status() async throws -> SwapperStatus {
        try Self.decode(SwapperStatus.self, try await authed("api/status"), "status")
    }

    public func swap(to key: String) async throws {
        let (code, data) = try await signedIn("api/swap", body: ["target": key])
        // A switch to a model the box hasn't installed says so in a field of its own.
        if code == 400, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["not_installed"] as? Bool == true {
            throw SwapperError.notInstalled
        }
        guard (200...299).contains(code) else { throw SwapperError.server(code, Self.message(data)) }
    }

    /// POST /api/models/install {"key"}: start installing a model the box doesn't have yet. A 409 means another
    /// install is running. Returns the install job.
    @discardableResult
    public func installModel(_ key: String) async throws -> SwapperStatus.Job? {
        let data: Data
        do {
            data = try await authed("api/models/install", body: ["key": key])
        } catch SwapperError.server(409, let message) {
            throw SwapperError.installBusy(message)
        } catch SwapperError.server(404, _) {
            throw SwapperError.unsupported("version 2.0")
        }
        return Self.job(in: data)
    }

    /// GET /api/provisioning/job: the install running now, or the last one.
    public func provisioningJob() async throws -> SwapperStatus.Job? {
        Self.job(in: try await authed("api/provisioning/job"))
    }

    private static func job(in data: Data) -> SwapperStatus.Job? {
        struct Wrapper: Decodable { var job: SwapperStatus.Job? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.job
    }

    /// GET /api/connect (Swapper 2.0): the model API's address, key and certificate.
    public func connectInfo() async throws -> SwapperConnectInfo {
        let data: Data
        do {
            data = try await authed("api/connect")
        } catch SwapperError.server(404, _) {
            throw SwapperError.unsupported("version 2.0")
        }
        return try Self.decode(SwapperConnectInfo.self, data, "connect")
    }

    /// GET /api/session — needs no sign-in; with a token it also says who the token belongs to.
    public func sessionInfo() async throws -> SwapperSessionInfo {
        let (code, data) = try await request("api/session")
        guard code == 200 else { throw SwapperError.server(code, Self.message(data)) }
        return try Self.decode(SwapperSessionInfo.self, data, "session")
    }

    /// POST /api/tokens/create (signed in with the username and password): an app token for this app.
    /// Throws `.unsupported` on a Swapper older than 2.0, which has no app tokens.
    public func createToken(label: String) async throws -> SwapperTokenGrant {
        let data: Data
        do {
            data = try await authed("api/tokens/create", body: ["label": label])
        } catch SwapperError.server(let code, _) where code == 404 || code == 405 {
            throw SwapperError.unsupported("version 2.0")
        }
        return try Self.decode(SwapperTokenGrant.self, data, "token")
    }

    /// GET /api/credentials: the model API's key and address (what an older Swapper offers instead of /api/connect).
    public func credentials() async throws -> SwapperCredentials {
        let data = try await authed("api/credentials")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let api = obj["api"] as? [String: Any] ?? [:]
        return SwapperCredentials(apiKey: api["key"] as? String, apiBase: api["base_url"] as? String,
                                  model: api["model"] as? String)
    }

    /// Connect without a pin to learn the certificate fingerprint to show the user.
    public static func probeFingerprint(_ url: URL) async -> String? {
        await CertificatePin.probe(url.appendingPathComponent("api/session"))
    }
}

// MARK: - Connection codes

/// What the Swapper's Connect tab hands an app ("Connect DSH"): `SSC1:` followed by base64url (no padding) of
/// UTF-8 JSON — the box's name and platform, the Swapper's and the model API's addresses, the model API key,
/// what it serves, the certificate fingerprint, and an app token.
public struct SwapperConnectionCode: Sendable, Equatable {
    public var name: String
    public var hostname: String?
    public var platform: String?
    public var version: String?
    public var swapperURL: URL
    public var apiBase: URL
    public var apiKey: String?
    public var model: String?
    public var context: Int?
    /// Canonical form ("3A:9F:…").
    public var fingerprint: String
    public var token: String
    public var user: String?

    public static let prefix = "SSC1:"

    /// What the user is told when the text isn't a code.
    public static let invalidMessage =
        "That doesn't look like a Spark Swapper connection code. Copy it again from the Swapper's Connect tab."

    /// Read a pasted code: whitespace (line breaks included) is ignored, the `SSC1:` prefix is optional (any
    /// case), base64url or standard base64 with or without padding, or the raw JSON object itself. Unknown keys
    /// are ignored; `swapper_url`, `api_base`, `fingerprint` and `token` are required, the addresses must be
    /// https and the fingerprint 32 hex pairs, and `v` must be 1 when present.
    public static func decode(_ text: String) throws -> SwapperConnectionCode {
        guard let object = jsonObject(text) else { throw SwapperCodeError() }
        if let version = object["v"], !(version is NSNull) {
            // (JSON's `true` arrives as a number too: it is not version 1.)
            guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == 1 else { throw SwapperCodeError() }
        }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let swapper = string("swapper_url").flatMap(httpsURL),
              let api = string("api_base").flatMap(httpsURL),
              let fingerprint = CertificatePin.normalized(string("fingerprint")),
              let token = string("token") else { throw SwapperCodeError() }
        var context: Int?
        if let number = object["context"] as? NSNumber { context = number.intValue }
        let hostname = string("hostname")
        let platform = string("platform")
        let name = string("name") ?? "\(SwapperPlatform.displayName(platform)) (\(hostname ?? swapper.host ?? "Swapper"))"
        return SwapperConnectionCode(name: name, hostname: hostname, platform: platform, version: string("version"),
                                     swapperURL: swapper, apiBase: api, apiKey: string("api_key"), model: string("model"),
                                     context: context, fingerprint: fingerprint, token: token, user: string("user"))
    }

    /// The JSON object inside the pasted text, or nil.
    private static func jsonObject(_ text: String) -> [String: Any]? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix(prefix) { body = String(body.dropFirst(prefix.count)) }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{") { return parse(Data(body.utf8)) }
        // base64url or standard base64, with or without padding, wherever the line breaks fell.
        var b64 = body.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard !b64.isEmpty, b64.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }) else { return nil }
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return parse(data)
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func httpsURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The code for these details (the Swapper's own encoding — used by tests, and to show a code again).
    public static func encode(_ fields: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return prefix + b64
    }

    /// The connect details the code carries (the same shape as GET /api/connect).
    public var connectInfo: SwapperConnectInfo {
        SwapperConnectInfo(name: name, hostname: hostname, platform: platform, version: version,
                           swapperURL: swapperURL.absoluteString, apiBase: apiBase.absoluteString, apiKey: apiKey,
                           model: model, context: context, fingerprint: fingerprint)
    }
}

/// A pasted text that isn't a connection code.
public struct SwapperCodeError: LocalizedError, Sendable, Equatable {
    public init() {}
    public var errorDescription: String? { SwapperConnectionCode.invalidMessage }
}
