import Foundation

// MARK: - Amazon Bedrock client (Converse API)
//
// Streams a turn through ConverseStream (POST /model/{modelId}/converse-stream on
// bedrock-runtime.{region}.amazonaws.com), whose reply is an AWS event stream rather than SSE, and
// lists models from the control plane (bedrock.{region}.amazonaws.com). Requests are signed with
// SigV4 from an `AWSCredentialSource` (the AWS CLI sign-in in the app), or carry a Bedrock API key as
// a bearer token. Request shaping lives in `BedrockConverse`, per-model facts in `BedrockModels`.
//
// AWS errors arrive as {"message": ...} with the type in the x-amzn-ErrorType header, or mid-stream
// as exception frames; both are mapped onto `LLMError` so `RequestRetry` classifies them: throttling
// and outages are waited out, a refused model or a bad request surfaces at once.

public struct BedrockClient: ProviderClient {
    /// A stream that sends nothing for this long is treated as dead (and retried). Long: with
    /// thinking hidden, Claude can think for minutes before the first visible byte. Seconds; a test
    /// hook as much as a setting.
    nonisolated(unsafe) public static var idleTimeout: TimeInterval = 600

    /// SigV4 signs both the runtime and the control plane as "bedrock".
    public static let signingName = "bedrock"

    /// How long `listModels` may take altogether. A test hook.
    nonisolated(unsafe) static var listModelsTimeout: TimeInterval = 20

    public let profile: ProviderProfile
    /// Nil when the profile uses a Bedrock API key (or has no sign-in yet — then every call explains that).
    let credentials: (any AWSCredentialSource)?
    private let session: URLSession
    private let clock: @Sendable () -> Date
    /// How far AWS's clock runs ahead of this machine's, learned from a "signature expired"
    /// refusal (a Mac clock minutes off makes every signature look stale). Shared by copies of the client.
    private let skew = ClockSkew()

    /// `credentials` is nil when the profile uses a Bedrock API key (or has no sign-in yet — then
    /// every call explains that). `session` replaces the network (tests); `clock` the time.
    public init(profile: ProviderProfile, credentials: (any AWSCredentialSource)?,
                session: URLSession? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.profile = profile
        self.credentials = credentials
        self.session = session ?? Self.sharedSession
        self.clock = clock
    }

    /// Clients are made per request and per retry; they share one session instead of leaking one
    /// URLSession each. Built for long streams: a request timeout that only backs up `idleTimeout`
    /// (which watches the stream itself), no waiting for connectivity (an unreachable network fails at
    /// once and the retry logic waits it out), no cache and no cookies.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 24 * 3_600
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// URLSession's own timeout, kept above `idleTimeout` so the stream watchdog's wording wins for a
    /// dead stream; what it adds is a bound on the wait for the response headers.
    private static var requestTimeout: TimeInterval { max(900, idleTimeout + 120) }

    private final class ClockSkew: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0
        var value: TimeInterval { lock.lock(); defer { lock.unlock() }; return seconds }
        func set(_ newValue: TimeInterval) { lock.lock(); seconds = newValue; lock.unlock() }
    }

    /// A Bedrock API key and no AWS profile: send the key as a bearer token instead of signing.
    public var usesAPIKey: Bool { profile.awsProfile == nil && !(profile.apiKey ?? "").isEmpty }

    // MARK: Endpoints

    private static let endpointRegion = try! NSRegularExpression(
        pattern: #"^bedrock(?:-runtime)?(?:-fips)?\.([a-z0-9-]+)\.amazonaws\.com$"#, options: [.caseInsensitive])

    /// The Region a standard endpoint host names ("bedrock-runtime.eu-west-1.amazonaws.com" → "eu-west-1").
    private static func standardRegion(host: String?) -> String? {
        guard let host else { return nil }
        guard let match = endpointRegion.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
              let range = Range(match.range(at: 1), in: host) else { return nil }
        return String(host[range])
    }

    /// The URL if `text` is an absolute one (`Uri.TryCreate(text, UriKind.Absolute)`).
    private static func absoluteURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    /// The profile's Region, else the one in a standard endpoint URL.
    public var region: String? {
        if let configured = profile.awsRegion, !BedrockConverse.isBlank(configured) {
            return configured.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let url = Self.absoluteURL(profile.baseURL) else { return nil }
        return Self.standardRegion(host: url.host?.lowercased())?.lowercased()
    }

    private func requireRegion() throws -> String {
        if let region { return region }
        throw LLMError.rejected(status: 400,
                                message: "Bedrock needs an AWS Region (such as us-east-1) — set one in Settings ▸ Models.",
                                body: "no AWS Region configured", permanent: true)
    }

    /// The runtime endpoint: the profile's base URL when it is an absolute http(s) URL (the wizard
    /// stores https://bedrock-runtime.{region}.amazonaws.com; a VPC endpoint or proxy works too), else
    /// the Region's public endpoint. A public endpoint for some other Region is stale (the Region was
    /// changed since) and follows the Region: signing for one Region and calling another is always
    /// refused.
    public var runtimeBase: String {
        get throws {
            if let url = Self.absoluteURL(profile.baseURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                let standard = Self.standardRegion(host: url.host?.lowercased())
                let configured = profile.awsRegion?.trimmingCharacters(in: .whitespacesAndNewlines)
                if standard == nil || BedrockConverse.isBlank(profile.awsRegion)
                    || standard?.lowercased() == configured?.lowercased() {
                    var base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    while base.hasSuffix("/") { base.removeLast() }
                    return base
                }
            }
            return "https://bedrock-runtime.\(try requireRegion()).amazonaws.com"
        }
    }

    /// The control-plane endpoint that lists models: the runtime host with "bedrock-runtime" swapped
    /// for "bedrock", else the Region's public one.
    public var controlBase: String {
        get throws {
            let runtime = try runtimeBase
            if let url = URL(string: runtime), let scheme = url.scheme?.lowercased(),
               let host = url.host?.lowercased(), host.hasPrefix("bedrock-runtime") {
                let isDefaultPort = url.port == nil || (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
                let port = isDefaultPort ? "" : ":\(url.port ?? 0)"
                return "\(scheme)://bedrock\(host.dropFirst("bedrock-runtime".count))\(port)"
            }
            return "https://bedrock.\(try requireRegion()).amazonaws.com"
        }
    }

    /// The ConverseStream URL. The model id is one path segment, percent-encoded like botocore does
    /// it: an inference-profile ARN's ':' and '/' become %3A and %2F.
    public func converseStreamURL(_ modelID: String) throws -> URL {
        let base = try runtimeBase
        return try Self.endpoint("\(base)/model/\(SigV4.encode(modelID))/converse-stream")
    }

    private static func endpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text) else {
            throw LLMError.rejected(status: 400,
                                    message: "The Bedrock endpoint \"\(text)\" is not a valid URL — check the endpoint in Settings ▸ Models.",
                                    body: "bad endpoint URL", permanent: true)
        }
        return url
    }

    // MARK: LLMClient

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await client.streamTurn(request) { _ = continuation.yield($0) }
                    continuation.finish()
                } catch let e as URLError where e.code == .cancelled {
                    // Our Stop, or the system dropping the request (which is worth retrying, not a
                    // reason to halt a queue).
                    continuation.finish(throwing: Task.isCancelled
                        ? CancellationError()
                        : LLMError.connection("the request was cancelled by the system"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamTurn(_ request: LLMRequest, emit: (LLMStreamEvent) -> Void) async throws {
        let model = BedrockConverse.modelID(request, profile)
        if BedrockConverse.isBlank(model) { throw LLMError.noModel }
        let (bytes, response) = try await openStream(request, model: model)
        // End the HTTP request whenever we stop reading (Stop, a dead stream, an error) instead of
        // leaving that to whoever releases the byte sequence last — the frame reader may still hold
        // it — or the model keeps generating for nobody.
        defer { bytes.task.cancel() }

        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            let mediaType = (contentType.split(separator: ";").first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if !mediaType.contains("eventstream") {
                // Something answered, but not Bedrock (a proxy's page, a wrong endpoint URL).
                let text = await Self.readErrorBody(bytes)
                try Task.checkCancellation()
                let flat = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
                throw LLMError.http(response.statusCode,
                                    "unrecognised reply (is the endpoint a Bedrock runtime URL?): \(flat.prefix(200))")
            }
        }

        var reply = ConverseReply { type, message in
            self.map(BedrockError(status: 0, type: type, message: message), model: model)
        }
        let limit = Self.idleTimeout
        do {
            for try await frame in Self.idleLimited(AWSEventStream.frames(from: bytes), limit: limit) {
                if let delta = try reply.handle(frame) { emit(delta) }
            }
        } catch let idle as IdleTimeout {
            throw LLMError.sse("no data from Bedrock for \(Int(idle.seconds)) s")
        } catch let error as AWSEventStreamError {
            throw LLMError.sse(error.message)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw LLMError.sse(error.localizedDescription)
        }
        // A cancelled reader sees its stream end quietly; that is Stop, not a short reply.
        try Task.checkCancellation()
        emit(try reply.finish())
    }

    // MARK: Watching a stream

    private struct IdleTimeout: Error { let seconds: TimeInterval }

    /// When the last frame arrived.
    private final class IdleClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = ProcessInfo.processInfo.systemUptime
        func touch() { lock.lock(); last = ProcessInfo.processInfo.systemUptime; lock.unlock() }
        func remaining(of limit: TimeInterval) -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return limit - (ProcessInfo.processInfo.systemUptime - last)
        }
    }

    /// `frames`, ended with `IdleTimeout` when none arrives for `limit` seconds — a stream whose
    /// server or network went away without closing the connection would otherwise hang the turn.
    private static func idleLimited(_ frames: AsyncThrowingStream<AWSEventMessage, Error>,
                                    limit: TimeInterval) -> AsyncThrowingStream<AWSEventMessage, Error> {
        let (stream, continuation) = AsyncThrowingStream<AWSEventMessage, Error>.makeStream()
        let idle = IdleClock()
        let pump = Task {
            do {
                for try await frame in frames {
                    idle.touch()
                    continuation.yield(frame)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                let remaining = idle.remaining(of: limit)
                if remaining <= 0 {
                    continuation.finish(throwing: IdleTimeout(seconds: limit))
                    return
                }
                // Sleep until the deadline, then look again: a frame in the meantime moved it.
                try? await Task.sleep(nanoseconds: UInt64(min(max(remaining, 0.001), 1_000_000) * 1_000_000_000))
            }
        }
        continuation.onTermination = { _ in
            pump.cancel()
            watchdog.cancel()
        }
        return stream
    }

    /// Send the turn; the open event-stream response. When Claude refuses the reasoning replayed
    /// from earlier turns (a changed history invalidates its signature; another model's reasoning
    /// isn't readable), the request goes again once without it.
    private func openStream(_ request: LLMRequest, model: String) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let url = try converseStreamURL(model)
        var replay = true
        while true {
            let body = BedrockConverse.request(request, profile: profile, replayReasoning: replay).serializedData()
            do {
                return try await send(method: "POST", url: url, body: body, model: model, timeout: Self.requestTimeout)
            } catch let error as LLMError
                        where replay && Self.status(of: error) == 400 && Self.rejectsReasoning(Self.body(of: error))
                              && request.messages.contains(where: { $0.providerState != nil }) {
                replay = false
            }
        }
    }

    private static func rejectsReasoning(_ body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("signature") || (lower.contains("thinking") && lower.contains("block"))
    }

    /// The HTTP status an error carries (an overflow is a 400), 0 for the ones that have none.
    private static func status(of error: LLMError) -> Int {
        switch error {
        case .http(let code, _): code
        case .rejected(let status, _, _, _): status
        case .overflow: 400
        case .noModel, .connection, .sse, .unsupported: 0
        }
    }

    /// The server's own wording an error carries, empty for the ones with none.
    private static func body(of error: LLMError) -> String {
        switch error {
        case .http(_, let body): body
        case .rejected(_, _, let body, _): body
        case .overflow(_, let detail): detail
        case .noModel, .connection, .sse, .unsupported: ""
        }
    }

    // MARK: Models

    /// Invokable model ids: foundation models that take on-demand traffic and stream text, then the
    /// Region's inference profiles (some models can only be called through one).
    public func listModels() async throws -> [String] {
        try await Self.withDeadline(Self.listModelsTimeout) {
            var ids: [String] = []
            let models = try await self.getJSON("foundation-models?byOutputModality=TEXT")
            for summary in models["modelSummaries"]?.array ?? [] where summary.object != nil {
                let onDemand = summary["inferenceTypesSupported"]?.array?.contains { $0.string == "ON_DEMAND" } ?? false
                // Streams unless it says it doesn't.
                let streams = summary["responseStreamingSupported"]?.bool ?? true
                if onDemand, streams, let id = summary["modelId"]?.string, !id.isEmpty { ids.append(id) }
            }
            var next: String?
            for _ in 0..<50 {
                let path = "inference-profiles?maxResults=1000" + (next.map { "&nextToken=" + SigV4.encode($0) } ?? "")
                let profiles = try await self.getJSON(path)
                for summary in profiles["inferenceProfileSummaries"]?.array ?? [] where summary.object != nil {
                    if let status = summary["status"]?.string, status != "ACTIVE" { continue }
                    if let id = summary["inferenceProfileId"]?.string, !id.isEmpty { ids.append(id) }
                }
                next = profiles["nextToken"]?.string
                if next?.isEmpty ?? true { break }
            }
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
    }

    /// `operation`, or `LLMError.connection` when it is not done within `seconds`.
    private static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                                  _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0.001), 1_000_000) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw CancellationError() }
                guard let value = first else { throw LLMError.connection("no answer within \(Int(seconds)) s") }
                return value
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            }
        }
    }

    private func getJSON(_ path: String) async throws -> JSONValue {
        let base = try controlBase
        let url = try Self.endpoint("\(base)/\(path)")
        let (bytes, _) = try await send(method: "GET", url: url, body: nil, model: profile.model,
                                        timeout: Self.listModelsTimeout + 10)
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        if let object = JSONValue(parsing: data), object.object != nil { return object }
        throw LLMError.sse("unexpected reply from \(url.path)")
    }

    /// The model's context window and output ceiling from the built-in table — Bedrock has no
    /// endpoint that reports them. No network call, so the route probe before every retry stays free.
    public func modelInfo(_ model: String?) async -> ModelInfo? {
        let id = model.flatMap { $0.isEmpty ? nil : $0 } ?? profile.model
        return ModelInfo(id: id, contextWindow: BedrockModels.contextWindow(id),
                         maxTokens: BedrockModels.traits(id).maxTokensCeiling)
    }

    // MARK: Sending

    /// Send one authorised request; the successful response (headers read, body unread). When AWS
    /// says the credentials expired, they are refreshed and the request sent once more; a clock that
    /// is off gets the same single retry with AWS's time. Anything else becomes an `LLMError`.
    private func send(method: String, url: URL, body: Data?, model: String,
                      timeout: TimeInterval) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var retried = false
        var refresh = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            // No compression: a compressed event stream would be buffered until the compressor
            // flushes, stalling live output.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            applyHeaders(&request)
            try await authorize(&request, body: body ?? Data(), refresh: refresh)

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch let error as URLError {
                if error.code == .cancelled {
                    if Task.isCancelled { throw CancellationError() }
                    throw LLMError.connection("the request was cancelled by the system")
                }
                // What waiting cannot fix — a certificate this Mac doesn't trust (a proxy that inspects TLS),
                // a malformed URL — surfaces at once instead of being retried for ever; the rest is an
                // outage to wait out.
                if RequestRetry.disposition(for: error) == .fail {
                    throw LLMError.rejected(status: 0,
                                            message: "Could not reach Amazon Bedrock: \(error.localizedDescription)",
                                            body: error.localizedDescription, permanent: true)
                }
                throw LLMError.connection(error.code == .timedOut ? "the request timed out" : error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw LLMError.connection("the reply was not an HTTP response")
            }
            if (200...299).contains(http.statusCode) { return (bytes, http) }

            let text = await Self.readErrorBody(bytes)
            try Task.checkCancellation()
            let error = BedrockError.from(http, body: text)
            if !retried, !usesAPIKey, credentials != nil, error.expiredCredentials {
                retried = true
                refresh = true
                continue
            }
            if !retried, error.clockSkew, let serverNow = Self.date(of: http) {
                retried = true
                skew.set(serverNow.timeIntervalSince(clock()))
                continue
            }
            throw map(error, model: model)
        }
    }

    /// The first 8 KB of an error reply (enough for any message; a proxy's HTML page can be huge).
    private static func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8_000 { break }
            }
        } catch {
            return ""
        }
        bytes.task.cancel() // not the rest of a page nobody will read
        return String(decoding: data, as: UTF8.self)
    }

    /// The response's Date header ("Tue, 29 Sep 2026 12:49:56 GMT"), if it has a readable one.
    private static func date(of response: HTTPURLResponse) -> Date? {
        guard let text = response.value(forHTTPHeaderField: "Date")?.trimmingCharacters(in: .whitespaces) else { return nil }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Bearer key, or a SigV4 signature over the exact body.
    private func authorize(_ request: inout URLRequest, body: Data, refresh: Bool) async throws {
        if usesAPIKey {
            request.setValue("Bearer \(profile.apiKey ?? "")", forHTTPHeaderField: "Authorization")
            return
        }
        guard let source = credentials else {
            throw LLMError.rejected(status: 401,
                                    message: "Bedrock needs an AWS sign-in: choose an AWS profile and sign in (Settings ▸ Models), or use a Bedrock API key.",
                                    body: "no AWS credentials", permanent: true)
        }
        let region = try requireRegion()
        let signing: AWSCredentials
        do {
            signing = try await source.credentials(forceRefresh: refresh)
        } catch let error as AWSSignInRequiredError {
            throw LLMError.rejected(status: 401, message: Self.signInExpired(error.profile), body: error.message, permanent: true)
        }
        try SigV4.sign(&request, body: body, credentials: signing, region: region, service: Self.signingName,
                       now: clock().addingTimeInterval(skew.value))
    }

    private static let signInExpiredStart = "The AWS sign-in for profile \""
    private static let signInExpiredEnd = "\" has expired."

    private static func signInExpired(_ profile: String) -> String {
        "\(signInExpiredStart)\(profile)\(signInExpiredEnd) Sign in again in Settings ▸ Models, or run `aws login --profile \(profile)`."
    }

    /// The AWS profile whose sign-in ran out, when `error` is the rejection this client raises for
    /// that; the host uses it to offer "Sign in". `LLMError` has no room for the underlying
    /// `AWSSignInRequiredError`, so the profile is read back from the message.
    public static func expiredSignInProfile(in error: Error) -> String? {
        guard case LLMError.rejected(let status, let message, _, let permanent) = error,
              status == 401, permanent, message.hasPrefix(signInExpiredStart) else { return nil }
        let start = message.index(message.startIndex, offsetBy: signInExpiredStart.count)
        guard let end = message.range(of: signInExpiredEnd, range: start..<message.endIndex) else { return nil }
        return String(message[start..<end.lowerBound])
    }

    /// User agent + the profile's custom headers (before signing, so x-amz-* ones are signed).
    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in profile.customHeaders ?? [:] where !BedrockConverse.isBlank(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "DSH-Mac/\(version ?? "dev")"
    }()

    // MARK: Errors

    /// An AWS error: HTTP status (0 inside a stream), the error type from x-amzn-ErrorType or the
    /// exception frame, and the message. `kind` is the type lower-cased and without its namespace or
    /// ":http://..." suffix.
    struct BedrockError: Equatable {
        let status: Int
        let type: String
        let message: String
        let kind: String

        init(status: Int, type: String, message: String) {
            self.status = status
            self.type = type
            self.message = message
            self.kind = Self.normalize(type)
        }

        private static func normalize(_ type: String) -> String {
            var t = type.components(separatedBy: ":")[0]
            if let hash = t.lastIndex(of: "#") { t = String(t[t.index(after: hash)...]) }
            return t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        static func from(_ response: HTTPURLResponse, body: String) -> BedrockError {
            var type = response.value(forHTTPHeaderField: "x-amzn-ErrorType") ?? ""
            var message = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let object = JSONValue(parsing: body), object.object != nil {
                message = object["message"]?.string ?? object["Message"]?.string ?? message
                if type.isEmpty { type = object["__type"]?.string ?? object["code"]?.string ?? "" }
            }
            return BedrockError(status: response.statusCode, type: type, message: message)
        }

        private var lower: String { message.lowercased() }

        /// The temporary credentials ran out (or were revoked): fetching fresh ones can fix it.
        var expiredCredentials: Bool {
            (status == 400 || status == 403)
                && (["expiredtokenexception", "expiredtoken", "unrecognizedclientexception", "invalidclienttokenid",
                     "tokenrefreshrequired"].contains(kind)
                    || lower.contains("security token included in the request is expired")
                    || lower.contains("security token included in the request is invalid")
                    || lower.contains("token has expired"))
        }

        /// The signature's timestamp is too far from AWS's clock.
        var clockSkew: Bool {
            ["requesttimetooskewed", "requestexpired"].contains(kind)
                || (kind == "invalidsignatureexception"
                    && (lower.contains("signature expired") || lower.contains("signature not yet current")))
        }

        var authentication: Bool {
            expiredCredentials || clockSkew
                || ["invalidsignatureexception", "incompletesignatureexception", "missingauthenticationtokenexception",
                    "signaturedoesnotmatch"].contains(kind)
        }
    }

    /// An AWS error as the `LLMError` the engine's retry logic expects.
    func map(_ e: BedrockError, model: String) -> LLMError {
        let region = self.region ?? "this Region"
        let detail = e.message.isEmpty ? e.type : e.message
        let body = e.type.isEmpty ? detail : "\(e.type.components(separatedBy: ":")[0]): \(detail)"
        let lower = detail.lowercased()
        if usesAPIKey, e.status == 401 || e.status == 403 || e.authentication,
           e.kind != "accessdeniedexception" || lower.contains("api key") || lower.contains("bearer") || lower.contains("authentication") {
            return .rejected(status: e.status == 0 ? 403 : e.status,
                             message: "Bedrock did not accept the API key (\(detail)). Short-term keys last at most 12 hours: create a new one, or sign in with AWS in Settings ▸ Models.",
                             body: body, permanent: true)
        }
        if e.authentication {
            let awsProfile = profile.awsProfile ?? "default"
            return .rejected(status: e.status == 0 ? 403 : e.status,
                             message: "AWS did not accept the credentials for profile \"\(awsProfile)\" (\(detail)). Sign in again in Settings ▸ Models, or run `aws login --profile \(awsProfile)`.",
                             body: body, permanent: true)
        }
        switch e.kind {
        case "validationexception":
            if Self.isOverflow(detail) { return .overflow(limit: Self.overflowLimit(detail) ?? 0, detail: detail) }
            return .rejected(status: 400, message: "Bedrock rejected the request: \(detail)", body: body, permanent: false)
        case "accessdeniedexception":
            var text = "Bedrock refused access to \(model) in \(region) (\(detail)). Your AWS account may need access to this model "
                + "enabled — the Bedrock setup in Settings ▸ Models can do that."
            if lower.contains("subscri") || lower.contains("marketplace") || lower.contains("not authorized") {
                text += " Right after a first-time subscription AWS can keep refusing for up to about 15 minutes; if you just enabled it, try again shortly."
            }
            return .rejected(status: 403, message: text, body: body, permanent: false)
        case "resourcenotfoundexception":
            // Unlike a local server swapping models, waiting won't make the id appear.
            return .rejected(status: 404,
                             message: "Bedrock has no model \"\(model)\" in \(region) (\(detail)). Check the model id and Region; some models can only be "
                                 + "called through an inference profile (an id starting with us., eu., apac. or global.).",
                             body: body, permanent: true)
        case "throttlingexception", "servicequotaexceededexception", "toomanyrequestsexception":
            return .rejected(status: 429, message: "Bedrock is throttling requests for \(model) (\(detail)).", body: body, permanent: false)
        case "modelnotreadyexception":
            return .rejected(status: 429, message: "\(model) is not ready on Bedrock yet (\(detail)).", body: body, permanent: false)
        case "serviceunavailableexception":
            return .rejected(status: 503, message: "Bedrock is unavailable (\(detail)).", body: body, permanent: false)
        case "modeltimeoutexception":
            return .rejected(status: 408, message: "\(model) timed out on Bedrock (\(detail)).", body: body, permanent: false)
        case "internalserverexception", "internalfailure", "modelerrorexception", "modelstreamerrorexception":
            return .rejected(status: 500, message: "Bedrock failed while running \(model) (\(detail)).", body: body, permanent: false)
        default:
            break
        }
        if (e.status == 0 || e.status == 400) && Self.isOverflow(detail) {
            return .overflow(limit: Self.overflowLimit(detail) ?? 0, detail: detail)
        }
        // The body itself was too big (many screenshots): the conversation must shrink, like an overflow.
        if e.status == 413 { return .overflow(limit: 0, detail: "request too large for Bedrock (HTTP 413)") }
        return .http(e.status == 0 ? 500 : e.status, body)
    }

    /// A refusal because the conversation (input plus the requested output) is too long for the
    /// model — compaction can fix that — as opposed to a request for more output than the model allows.
    static func isOverflow(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("context window") || lower.contains("context length") || lower.contains("context limit") { return true }
        let aboutOutput = lower.contains("max_tokens") || lower.contains("maxtokens") || lower.contains("maximum tokens")
            || lower.contains("output tokens")
        let tooBig = lower.contains("too long") || lower.contains("exceed") || lower.contains("too many")
        return tooBig && (lower.contains("input") || lower.contains("prompt")) && !aboutOutput
    }

    // Claude: "prompt is too long: 215000 tokens > 200000 maximum"; "input length and `max_tokens`
    // exceed context limit: 180000 + 32000 > 200000".
    private static let limitPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #">\s*(\d{4,})"#),
        try! NSRegularExpression(pattern: #"maximum (?:length |context length )?(?:of |is )?(\d{4,})"#, options: [.caseInsensitive]),
    ]

    /// The window an overflow message names, if any.
    static func overflowLimit(_ message: String) -> Int? {
        if let known = OpenAIClient.overflowLimit(in: message) { return known }
        for regex in limitPatterns {
            if let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
               let range = Range(match.range(at: 1), in: message),
               let number = Int32(message[range]), number > 0 {
                return Int(number)
            }
        }
        return nil
    }
}
