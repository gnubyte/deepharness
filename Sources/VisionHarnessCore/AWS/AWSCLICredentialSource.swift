import Foundation

// MARK: - Credentials from the AWS CLI
//
// `aws configure export-credentials --format process` resolves a profile exactly as every AWS tool
// does — refreshing an `aws login` session or an IAM Identity Center token when it has to — and prints
// the result as the credential_process JSON (awscli/customizations/configure/exportcreds.py):
//   {"Version": 1, "AccessKeyId": "...", "SecretAccessKey": "...", "SessionToken": "...",
//    "Expiration": "2026-09-29T19:55:23.728587+00:00"}
// SessionToken and Expiration are absent for long-term access keys. The app keeps the answer until
// five minutes before it expires, so a chat turn usually costs no CLI run at all.

/// AWS credentials for one CLI profile, fetched with `aws configure export-credentials` and cached
/// until shortly before they expire.
public final class AWSCLICredentialSource: AWSCredentialSource, @unchecked Sendable {
    /// The AWS CLI profile (e.g. "vision-bedrock").
    public let profile: String

    /// Passed as --region; nil lets the profile's own Region apply. The CLI refreshes an `aws login`
    /// session through that Region's sign-in endpoint, so it must have one: `AWSSignIn.login` saves the
    /// Region into the profile for this reason.
    public let region: String?

    /// Fetch again this many seconds before the credentials expire.
    public let refreshMargin: TimeInterval

    /// How long one export may take, in seconds (a refresh is a network call to AWS).
    public let timeout: TimeInterval

    private let cli: AWSCLI
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: AWSCredentials?
    private var inFlight: Flight?

    /// A blank profile name means the CLI's default profile.
    public init(cli: AWSCLI, profile: String, region: String? = nil, refreshMargin: TimeInterval = 5 * 60,
                timeout: TimeInterval = 120, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cli = cli
        let name = AWSCLIText.trimmed(profile)
        self.profile = name.isEmpty ? "default" : name
        self.region = region
        self.refreshMargin = refreshMargin
        self.timeout = timeout
        self.now = now
    }

    public convenience init(runner: any AWSCLIRunner, profile: String, region: String? = nil,
                            refreshMargin: TimeInterval = 5 * 60, timeout: TimeInterval = 120,
                            now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(cli: AWSCLI(runner: runner), profile: profile, region: region, refreshMargin: refreshMargin,
                  timeout: timeout, now: now)
    }

    /// The arguments the app runs.
    public var exportArguments: [String] {
        AWSCLI.arguments(["configure", "export-credentials", "--format", "process"], profile: profile, region: region, json: false)
    }

    /// Cached credentials while they have more than `refreshMargin` left; otherwise (or with
    /// `forceRefresh`) a fresh export. Callers arriving while an export runs share it. Throws
    /// `AWSSignInRequiredError` when the user has to sign in again, and `AWSCLIException` for other
    /// failures. One caller giving up (its task cancelled) doesn't stop the export the others are
    /// waiting for.
    public func credentials(forceRefresh: Bool = false) async throws -> AWSCredentials {
        enum Plan {
            case cached(AWSCredentials)
            case join(Flight)
            case start(Flight)
        }
        let plan: Plan = lock.withLock {
            if !forceRefresh, inFlight == nil, let cached, !cached.expiresWithin(refreshMargin, now: now()) { return .cached(cached) }
            if let inFlight { return .join(inFlight) }
            let flight = Flight()
            inFlight = flight
            return .start(flight)
        }
        switch plan {
        case .cached(let credentials):
            return credentials
        case .join(let flight):
            return try await flight.wait()
        case .start(let flight):
            // A task of its own: it belongs to everyone waiting, not to the caller that started it.
            Task { await export(flight) }
            return try await flight.wait()
        }
    }

    /// Forget the cached credentials (after signing in again, or out).
    public func invalidate() {
        lock.withLock { cached = nil }
    }

    private func export(_ flight: Flight) async {
        do {
            let result = try await cli.runner.run(exportArguments, options: AWSCLIRunOptions(timeout: timeout))
            if !result.succeeded {
                throw AWSCLIErrors.toError(AWSCLIErrors.classify(result, service: "configure"), profile: profile)
            }
            let credentials = try Self.parseProcessOutput(result.stdout, profile: profile)
            lock.withLock {
                cached = credentials
                inFlight = nil
            }
            flight.finish(.success(credentials))
        } catch {
            lock.withLock { inFlight = nil }
            flight.finish(.failure(error))
        }
    }

    /// One export in progress and everyone waiting for it. A waiter can leave (its task cancelled)
    /// without disturbing the export or the others.
    private final class Flight: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<AWSCredentials, any Error>?
        private var waiters: [Int: CheckedContinuation<AWSCredentials, any Error>] = [:]
        private var nextID = 0

        func wait() async throws -> AWSCredentials {
            let id: Int = lock.withLock {
                defer { nextID += 1 }
                return nextID
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AWSCredentials, any Error>) in
                    let immediate: Result<AWSCredentials, any Error>? = lock.withLock {
                        if let outcome { return outcome }
                        if Task.isCancelled { return .failure(CancellationError()) }
                        waiters[id] = continuation
                        return nil
                    }
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: {
                let leaving = lock.withLock { waiters.removeValue(forKey: id) }
                leaving?.resume(throwing: CancellationError())
            }
        }

        func finish(_ result: Result<AWSCredentials, any Error>) {
            let all: [CheckedContinuation<AWSCredentials, any Error>] = lock.withLock {
                outcome = result
                let all = Array(waiters.values)
                waiters.removeAll()
                return all
            }
            for waiter in all { waiter.resume(with: result) }
        }
    }

    // MARK: Reading what the CLI printed

    /// Read the credential_process JSON. Expiration is ISO 8601 (Python's isoformat, e.g.
    /// "2026-09-29T19:55:23.728587+00:00", or "…Z").
    public static func parseProcessOutput(_ json: String, profile: String = "default") throws -> AWSCredentials {
        let object = JSONValue(parsing: json)?.object
        guard let accessKey = object?["AccessKeyId"]?.string, !accessKey.isEmpty,
              let secret = object?["SecretAccessKey"]?.string, !secret.isEmpty else {
            // Nothing usable came back: treat it as "not signed in" rather than a crash.
            throw AWSSignInRequiredError(profile: profile, message: "The AWS CLI didn't return credentials for this profile. Sign in again.")
        }
        let token = object?["SessionToken"]?.string
        var expiration: Date?
        if let text = object?["Expiration"]?.string, !text.isEmpty {
            guard let parsed = parseTimestamp(text) else {
                throw AWSCLIException(AWSCLIError(kind: .other, message: "The AWS CLI returned an expiry time Vision couldn't read (\(text)).", details: text))
            }
            expiration = parsed
        }
        return AWSCredentials(accessKeyID: accessKey, secretAccessKey: secret,
                              sessionToken: (token ?? "").isEmpty ? nil : token, expiration: expiration)
    }

    /// "2026-09-29T19:55:23.728587+00:00", "2026-09-29T20:00:00Z", "2026-09-29 20:00:00" (no zone
    /// means UTC). `ISO8601DateFormatter` keeps only milliseconds, so this reads the parts itself.
    static func parseTimestamp(_ text: String) -> Date? {
        guard let match = timestampRegex.firstMatch(in: AWSCLIText.trimmed(text)) else { return nil }
        func number(_ index: Int) -> Int? { match.group(at: index).flatMap { Int($0) } }
        guard let year = number(1), let month = number(2), let day = number(3),
              let hour = number(4), let minute = number(5), let second = number(6) else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard components.isValidDate(in: calendar), let base = calendar.date(from: components) else { return nil }
        let fraction = match.group(at: 7).flatMap { Double("0." + $0) } ?? 0
        var offset = 0.0
        if let zone = match.group(at: 8), zone != "Z", zone != "z" {
            let digits = zone.dropFirst().filter { $0 != ":" }
            guard let hours = Int(digits.prefix(2)), let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) : 0,
                  hours <= 23, minutes <= 59 else { return nil }
            offset = Double(hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        return base.addingTimeInterval(fraction - offset)
    }

    private static let timestampRegex = AWSCLIRegex(
        #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$"#)
}
