import Foundation
import CryptoKit
import Security

// MARK: - Certificate pinning
//
// A box on your own network (the Spark Swapper at :8999, the HTTPS front it puts on the model API at :11443)
// uses a self-signed certificate the system doesn't trust. Such a server is trusted by the SHA-256 fingerprint
// of its leaf certificate, written the way openssl prints it ("3A:9F:…:C2") — the user approves it once, or a
// Swapper connection code carries it. Anything else is refused: a pin never means "accept anything".

public enum CertificatePin {
    /// "AB:CD:…" — the SHA-256 of a DER certificate, uppercase hex pairs joined by ":".
    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The fingerprint of the leaf certificate a server presented.
    public static func fingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return fingerprint(der: SecCertificateCopyData(leaf) as Data)
    }

    /// A fingerprint as a person or a server wrote it — any case, with or without the colons — in the canonical
    /// form; nil when it isn't 32 hex pairs.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = raw.uppercased().filter { !$0.isWhitespace && $0 != ":" }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }

    /// Whether two fingerprints are the same certificate (case and colons don't matter).
    public static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a = normalized(a), let b = normalized(b) else { return false }
        return a == b
    }

    /// "SHA-256 3A:9F:…:C2" shortened for a sentence: the first and last few pairs.
    public static func short(_ fingerprint: String) -> String {
        let pairs = fingerprint.split(separator: ":")
        guard pairs.count > 8 else { return fingerprint }
        return pairs.prefix(4).joined(separator: ":") + ":…:" + pairs.suffix(4).joined(separator: ":")
    }

    /// Connect to `url` without trusting anything, to learn the fingerprint of the certificate it presents
    /// (shown to the user before they choose to trust it). Nil when nothing answered over TLS.
    public static func probe(_ url: URL) async -> String? {
        let delegate = PinningDelegate(pinned: nil, mode: .pinOnly)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(DSHIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: request)
        return delegate.seenFingerprint
    }
}

/// How a connection's certificate is checked.
public enum PinningMode: Sendable, Equatable {
    /// System trust first; failing that, the pinned fingerprint (a route to a self-signed box).
    case systemThenPin
    /// Only the pinned fingerprint counts, whatever the system thinks — checking a Swapper connection code: the
    /// certificate presented must be the one the code names.
    case pinOnly
}

/// What to do with one server-trust challenge.
enum TrustDecision: Equatable {
    /// Accept the certificate.
    case accept
    /// Let the system decide (it refuses an untrusted certificate with a certificate error).
    case systemDecides
    /// Refuse outright (the request fails as cancelled).
    case refuse
}

/// Trust handling for a URLSession: system trust and/or one pinned fingerprint (see `PinningMode`). It also
/// remembers the fingerprint of each host's certificate, so an error can say which certificate was refused.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pinned: String?
    let mode: PinningMode
    private let lock = NSLock()
    private var _seen: String?
    private var byHost: [String: String] = [:]

    init(pinned: String?, mode: PinningMode = .systemThenPin) {
        self.pinned = CertificatePin.normalized(pinned) ?? pinned
        self.mode = mode
    }

    /// The fingerprint of the last certificate that wasn't trusted without the pin (or, in `pinOnly` mode, the
    /// last one presented).
    var seenFingerprint: String? { lock.withLock { _seen } }

    /// The fingerprint of the certificate `host` presented last.
    func fingerprint(host: String?) -> String? {
        guard let host else { return nil }
        return lock.withLock { byHost[host.lowercased()] }
    }

    /// The decision, apart from the TLS machinery so it can be tested. `systemTrusted` is only asked when it
    /// matters.
    static func decide(fingerprint: String?, pinned: String?, mode: PinningMode,
                       systemTrusted: () -> Bool) -> TrustDecision {
        switch mode {
        case .pinOnly:
            return CertificatePin.matches(fingerprint, pinned) ? .accept : .refuse
        case .systemThenPin:
            if systemTrusted() { return .accept }
            // Not trusted by the system: the pin, or the system's own refusal (a certificate error, not a
            // cancelled request — so it is never mistaken for a dropped connection and retried).
            return CertificatePin.matches(fingerprint, pinned) ? .accept : .systemDecides
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let fp = CertificatePin.fingerprint(trust)
        let host = challenge.protectionSpace.host.lowercased()
        var systemTrusted: Bool?
        let decision = Self.decide(fingerprint: fp, pinned: pinned, mode: mode) {
            let trusted = SecTrustEvaluateWithError(trust, nil)
            systemTrusted = trusted
            return trusted
        }
        lock.withLock {
            if let fp {
                byHost[host] = fp
                if mode == .pinOnly || systemTrusted == false { _seen = fp }
            }
        }
        switch decision {
        case .accept: completionHandler(.useCredential, URLCredential(trust: trust))
        case .systemDecides: completionHandler(.performDefaultHandling, nil)
        case .refuse: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// URL errors that mean "the certificate wasn't trusted".
    static let certificateFailures: Set<URLError.Code> = [
        .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .secureConnectionFailed,
    ]
}

// MARK: - Who is calling

/// How DSH names itself to the servers it calls. Some plans (Kimi Code) check which app is calling: DSH says
/// honestly that it is DSH, and never borrows another tool's identity.
public enum DSHIdentity {
    /// The app's version from its bundle ("0.14.0"); "dev" in a test run or an unbundled build.
    public static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (short?.isEmpty == false && Bundle.main.bundlePath.hasSuffix(".app")) ? short! : "dev"
    }

    /// "DSH/0.14.0 (macOS)"
    public static var userAgent: String { "DSH/\(version) (macOS)" }
}
