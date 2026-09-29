import Foundation

// MARK: - Retrying model calls
//
// A model server on the desk (the Spark) goes away for ordinary reasons: it is
// swapping models (minutes), restarting, loading a model cold (~11 min for
// Flash), prefilling a huge context slower than the idle timeout, or simply
// overloaded. None of those should kill a chat turn, a `/goal`, or a week-long
// task queue. So a model call that fails for a reason that can fix itself is
// retried — with backoff, indefinitely — until the server answers or the user
// presses Stop (task cancellation ends the wait at once). Failures that can't
// fix themselves (a malformed request, bad credentials, a bad URL) surface
// immediately instead of spinning.

/// How a failed model call should be handled.
public enum RetryDisposition: Equatable, Sendable {
    /// Surface the error now; trying again cannot help.
    case fail
    /// The server is unreachable, slow, restarting or busy: retry until it answers.
    case untilAvailable
    /// The server answered but choked on this request (HTTP 500): often
    /// transient (an OOM, a worker restart), sometimes deterministic — retry a
    /// bounded number of times, then surface it.
    case limited(Int)
}

/// Retry settings for an engine's model calls.
public struct RetryPolicy: Sendable {
    /// False disables retrying entirely (every failure surfaces at once).
    public var enabled: Bool
    /// Seconds to wait before retry attempt `n` (1-based).
    public var delay: @Sendable (Int) -> TimeInterval

    public init(enabled: Bool = true,
                delay: @escaping @Sendable (Int) -> TimeInterval = RequestRetry.backoff(attempt:)) {
        self.enabled = enabled
        self.delay = delay
    }

    /// Retry transient failures indefinitely with the standard backoff.
    public static let standard = RetryPolicy()
    /// Never retry.
    public static let off = RetryPolicy(enabled: false)

    /// Whether to try again after the `attempt`-th consecutive failure (1-based).
    public func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard enabled else { return false }
        switch RequestRetry.disposition(for: error) {
        case .fail: return false
        case .untilAvailable: return true
        case .limited(let n): return attempt <= n
        }
    }
}

public enum RequestRetry {
    /// Backoff: 2s, 4s, 8s, 16s, then every 30s for as long as it takes.
    public static func backoff(attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        if n >= 5 { return 30 }
        return TimeInterval(1 << n)   // 2, 4, 8, 16
    }

    /// How many times an HTTP 500 is retried before it is reported.
    public static let serverErrorRetries = 8

    /// Classify a model-call failure.
    public static func disposition(for error: Error) -> RetryDisposition {
        if error is CancellationError { return .fail }
        if let llm = error as? LLMError {
            switch llm {
            case .noModel, .unsupported, .overflow:
                return .fail
            case .connection, .sse:
                // Unreachable, or the stream was cut off mid-reply.
                return .untilAvailable
            case .http(let code, let body):
                return disposition(httpStatus: code, body: body)
            }
        }
        if let url = error as? URLError { return disposition(urlCode: url.code) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return disposition(urlCode: URLError.Code(rawValue: ns.code)) }
        // Socket-level failures (connection reset/refused) that escape URLSession's mapping.
        if ns.domain == NSPOSIXErrorDomain { return .untilAvailable }
        return .fail
    }

    static func disposition(urlCode code: URLError.Code) -> RetryDisposition {
        switch code {
        case .cancelled,
             .badURL, .unsupportedURL,
             .userAuthenticationRequired, .userCancelledAuthentication,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection,
             .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile,
             .dataLengthExceedsMaximum:
            return .fail
        default:
            // timedOut, cannotConnectToHost, networkConnectionLost,
            // notConnectedToInternet, cannotFindHost, dnsLookupFailed,
            // badServerResponse, secureConnectionFailed, resourceUnavailable, …
            return .untilAvailable
        }
    }

    static func disposition(httpStatus code: Int, body: String) -> RetryDisposition {
        switch code {
        case 408, 409, 425, 429, 502, 503, 504, 507, 520...524, 529, 598, 599:
            // Timeout, overloaded, gateway can't reach the model (nginx in
            // front of a server that is down or restarting).
            return .untilAvailable
        case 500:
            return .limited(serverErrorRetries)
        case 404:
            // "The model `x` does not exist" while the Spark swaps models: the
            // route re-resolves between attempts, so this heals itself.
            let lower = body.lowercased()
            if lower.contains("model"),
               lower.contains("not found") || lower.contains("does not exist") || lower.contains("not exist")
                || lower.contains("unknown") || lower.contains("not loaded") || lower.contains("loading") {
                return .untilAvailable
            }
            return .fail
        case 400:
            // A few servers say "still loading" with a 400.
            let lower = body.lowercased()
            if lower.contains("loading model") || lower.contains("model is loading") || lower.contains("model is not loaded")
                || lower.contains("server is starting") || lower.contains("not ready") {
                return .untilAvailable
            }
            return .fail
        default:
            return code >= 500 ? .limited(serverErrorRetries) : .fail
        }
    }

    /// A short, plain reason for the status line ("timed out", "server unreachable").
    public static func reason(for error: Error) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .http(let code, let body):
                let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                return snippet.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(snippet.prefix(80))"
            case .sse(let why): return "stream cut off (\(why.prefix(80)))"
            case .connection(let why): return "server unreachable (\(why.prefix(80)))"
            default: return llm.errorDescription ?? "\(llm)"
            }
        }
        let code: URLError.Code?
        if let url = error as? URLError {
            code = url.code
        } else if (error as NSError).domain == NSURLErrorDomain {
            code = URLError.Code(rawValue: (error as NSError).code)
        } else {
            code = nil
        }
        if let code {
            switch code {
            case .timedOut: return "the request timed out"
            case .cannotConnectToHost: return "the server refused the connection"
            case .networkConnectionLost: return "the connection dropped"
            case .notConnectedToInternet: return "no network connection"
            case .cannotFindHost, .dnsLookupFailed: return "the server's address can't be found"
            case .secureConnectionFailed: return "the secure connection failed"
            case .badServerResponse: return "the server sent a bad response"
            default: break
            }
        }
        return error.localizedDescription
    }
}
