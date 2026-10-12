import Foundation

// MARK: - Backups for the primary
//
// The primary model is wrapped so that a request it fails *before any output arrived* — it couldn't be reached,
// timed out, refused the key (401/403), lost the model (404), was busy (408, 429) or broke (5xx) — is tried on each
// backup in turn. A turn that ran on a backup is reported, so the chat can say so. When every candidate fails, the
// primary's own error is what comes out, so the usual outage retry and back-off take over unchanged. Nothing ever
// fails over mid-stream: once the primary has started answering, its answer is the answer. (Subagents don't use
// backups — the fleet already moves their tasks between servers.)

/// A turn that ran on a backup.
public struct FailoverNotice: Sendable, Equatable {
    public var primary: String
    public var backup: String
    /// Why the primary didn't answer ("the server refused the connection", "HTTP 503: overloaded").
    public var reason: String

    public init(primary: String, backup: String, reason: String) {
        self.primary = primary
        self.backup = backup
        self.reason = reason
    }

    /// "Spark didn't answer (the server refused the connection), so this turn ran on Kimi Code."
    public var text: String { "\(primary) didn't answer (\(reason)), so this turn ran on \(backup)." }
}

public struct FailoverClient: ProviderClient {
    public let primary: any ProviderClient
    public let backups: [any ProviderClient]
    /// Called (on any thread) when a request ran on a backup.
    public let onFailover: @Sendable (FailoverNotice) -> Void
    private let state: FailoverState

    /// How long the primary is passed over (tried last instead of first) after it failed — so a multi-step turn
    /// doesn't wait for a dead server on every step.
    public static let coolDown: TimeInterval = 60

    public init(primary: any ProviderClient, backups: [any ProviderClient],
                now: @escaping @Sendable () -> Date = { Date() },
                onFailover: @escaping @Sendable (FailoverNotice) -> Void = { _ in }) {
        self.primary = primary
        self.backups = backups
        self.onFailover = onFailover
        self.state = FailoverState(now: now)
    }

    public var profile: ProviderProfile { primary.profile }

    public func listModels() async throws -> [String] { try await primary.listModels() }

    public func modelInfo(_ model: String?) async -> ModelInfo? { await primary.modelInfo(model) }

    /// Whether a failure that came before any output means "try a backup": the server couldn't be reached or
    /// timed out, refused the key, lost the model, was busy, or broke.
    public static func failsOver(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let llm = error as? LLMError {
            switch llm {
            case .connection, .sse:
                return true
            case .http(let status, _), .rejected(let status, _, _, _):
                return [401, 403, 404, 408, 429, OpenAIClient.untrustedCertificateStatus].contains(status) || (500...599).contains(status)
            case .noModel, .unsupported, .overflow:
                return false
            }
        }
        if let url = error as? URLError { return url.code != .cancelled }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let primary = self.primary, backups = self.backups, state = self.state, report = self.onFailover
        return AsyncThrowingStream { continuation in
            let task = Task {
                // The primary first — unless it failed a moment ago, then it goes last.
                let passedOver = state.primaryResting
                var order: [(client: any ProviderClient, isPrimary: Bool)] = [(primary, true)] + backups.map { ($0, false) }
                if passedOver, !backups.isEmpty { order.append(order.removeFirst()) }
                var primaryError: Error?
                var firstFailure: Error?
                for candidate in order {
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    var sent = request
                    if !candidate.isPrimary { sent = request.with(model: candidate.client.profile.model) }
                    var started = false
                    do {
                        for try await event in candidate.client.stream(sent) {
                            if !started {
                                started = true
                                if candidate.isPrimary {
                                    state.primaryAnswered()
                                } else {
                                    let why = primaryError ?? state.lastPrimaryError
                                    report(FailoverNotice(primary: Self.label(primary.profile), backup: Self.label(candidate.client.profile),
                                                          reason: why.map(RequestRetry.reason(for:)) ?? "it failed a moment ago"))
                                }
                            }
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch {
                        // Mid-stream, or stopped: that's the answer.
                        if started || error is CancellationError || Task.isCancelled {
                            continuation.finish(throwing: error)
                            return
                        }
                        if firstFailure == nil { firstFailure = error }
                        if candidate.isPrimary {
                            primaryError = error
                            // A failure that isn't the server's (a malformed request, an overflow): no backup helps.
                            guard Self.failsOver(error), !backups.isEmpty else {
                                continuation.finish(throwing: error)
                                return
                            }
                            state.primaryFailed(error)
                        }
                    }
                }
                // Everyone failed: the primary's error, so the usual outage handling takes over.
                continuation.finish(throwing: primaryError ?? state.lastPrimaryError ?? firstFailure ?? LLMError.connection("no model answered"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How a route is named in the notice: its own name, else its model.
    static func label(_ profile: ProviderProfile) -> String {
        profile.name.isEmpty ? profile.model : profile.name
    }
}

/// When the primary last failed, shared by every request through one `FailoverClient`.
final class FailoverState: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var failedAt: Date?
    private var error: Error?

    init(now: @escaping @Sendable () -> Date) { self.now = now }

    /// The primary failed less than `FailoverClient.coolDown` ago.
    var primaryResting: Bool {
        lock.withLock { failedAt.map { now().timeIntervalSince($0) < FailoverClient.coolDown } ?? false }
    }

    var lastPrimaryError: Error? { lock.withLock { error } }

    func primaryFailed(_ error: Error) {
        lock.withLock {
            failedAt = now()
            self.error = error
        }
    }

    func primaryAnswered() {
        lock.withLock {
            failedAt = nil
            error = nil
        }
    }
}

extension LLMRequest {
    /// The same request for another model (a backup serves its own).
    func with(model: String) -> LLMRequest {
        LLMRequest(systemPrompt: systemPrompt, messages: messages, tools: tools, model: model,
                   temperature: temperature, maxTokens: maxTokens, thinking: thinking)
    }
}
