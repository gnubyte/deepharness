import Foundation
import CryptoKit
import Security

// MARK: - Spark Swapper client
//
// Talks to the Spark Swapper web service (https://<spark>:8999) that stops one
// model server on the DGX Spark and starts another. Same API the web page
// uses: POST /api/login (cookie session), GET /api/status, POST /api/swap.
//
// The service uses a self-signed certificate. If the system doesn't trust it,
// the client pins the leaf certificate's SHA-256 fingerprint the user approved
// once (trust on first use) and refuses anything else.

public struct SwapperStatus: Decodable, Sendable, Equatable {
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
        public var id: String { key }
    }

    public struct Step: Decodable, Sendable, Equatable {
        public var key: String
        public var label: String
        public var state: String
    }

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

        public var isRunning: Bool { state == "running" }
        public var currentStep: Step? { steps.first { $0.state == "running" } ?? steps.last { $0.state == "failed" } }
    }

    public var active: String?
    public var loading: String?
    public var busy: Bool
    public var models: [String: Model]
    public var job: Job?
    public var openclaw_primary: String?

    /// Models in display order.
    public var ordered: [Model] {
        models.values.sorted { ($0.order ?? 9, $0.title) < ($1.order ?? 9, $1.title) }
    }

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

public enum SwapperError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case untrustedCertificate(fingerprint: String)
    case badLogin(String)
    case server(Int, String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "The Spark swapper isn't set up. Add its address and login in Settings ▸ Spark."
        case .untrustedCertificate(let fp): "The Spark swapper's certificate isn't trusted yet (SHA-256 \(fp.prefix(23))…). Approve it in Settings ▸ Spark."
        case .badLogin(let m): "Spark swapper login failed: \(m)"
        case .server(let code, let m): "Spark swapper replied \(code): \(m)"
        case .transport(let m): "Couldn't reach the Spark swapper: \(m)"
        }
    }
}

/// Trust handling: system trust first, then the one pinned fingerprint.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pinned: String?
    private let lock = NSLock()
    private var _seen: String?
    var seenFingerprint: String? { lock.lock(); defer { lock.unlock() }; return _seen }

    init(pinned: String?) { self.pinned = pinned }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        let fp = Self.fingerprint(trust)
        lock.lock(); _seen = fp; lock.unlock()
        if let fp, let pinned, fp == pinned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func fingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public final class SparkSwapperClient: @unchecked Sendable {
    public let baseURL: URL
    private let username: String
    private let password: String
    private let delegate: PinningDelegate
    private let session: URLSession
    private var loggedIn = false
    private let lock = NSLock()

    public init(baseURL: URL, username: String, password: String, pinnedFingerprint: String?) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.delegate = PinningDelegate(pinned: pinnedFingerprint)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// A reasonable swapper address for a model server URL: same host, port 8999.
    public static func defaultURL(forModelServer base: String) -> String? {
        guard let host = URL(string: base)?.host, !host.isEmpty else { return nil }
        return "https://\(host):8999"
    }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.setValue("1", forHTTPHeaderField: "X-Swapper")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let e as URLError where e.code == .cancelled || e.code == .serverCertificateUntrusted
                    || e.code == .secureConnectionFailed || e.code == .serverCertificateHasUnknownRoot {
            if let fp = delegate.seenFingerprint, fp != delegate.pinned {
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

    public func login() async throws {
        let (code, data) = try await request("api/login", body: ["username": username, "password": password])
        guard code == 200 else { throw SwapperError.badLogin(Self.message(data)) }
        setLoggedIn(true)
    }

    /// Call `path`, logging in first (or again, after a 401).
    private func authed(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        if !isLoggedIn { try await login() }
        var (code, data) = try await request(path, body: body)
        if code == 401 {
            try await login()
            (code, data) = try await request(path, body: body)
        }
        guard (200...299).contains(code) else { throw SwapperError.server(code, Self.message(data)) }
        return data
    }

    public func status() async throws -> SwapperStatus {
        let data = try await authed("api/status")
        do {
            return try JSONDecoder().decode(SwapperStatus.self, from: data)
        } catch {
            throw SwapperError.transport("unexpected status payload (\(error.localizedDescription))")
        }
    }

    public func swap(to key: String) async throws {
        _ = try await authed("api/swap", body: ["target": key])
    }

    /// Connect without a pin to learn the certificate fingerprint to show the user.
    public static func probeFingerprint(_ url: URL) async -> String? {
        let probe = SparkSwapperClient(baseURL: url, username: "", password: "", pinnedFingerprint: nil)
        _ = try? await probe.request("api/session")
        return probe.delegate.seenFingerprint
    }
}
