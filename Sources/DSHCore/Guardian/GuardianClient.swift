import Foundation

// MARK: - Guardian as a model provider
//
// Guardian (guardian.503cm.com) fronts the models an account may use behind
// one OpenAI-compatible harness endpoint:
//
//     POST /api/harness/v1/chat/completions
//     GET  /api/harness/v1/models
//
// Signing in exchanges email + password (+ a TOTP step for 2FA accounts) for a
// long-lived bearer token the app keeps in the Keychain. The service in the
// app layer turns each allowed model into a normal provider route, so a
// Guardian model and a local DGX Spark model are simply two entries in the
// model menu — either can lead, either can take subagent work, both stay
// configured at once.

public struct GuardianSession: Codable, Hashable, Sendable {
    /// The signed-in user, as Guardian reports them.
    public var userID: String
    public var email: String
    public var name: String?
    /// The bearer token for harness calls.
    public var token: String
    /// When the token was issued; Guardian says how long it lasts.
    public var issuedAt: Date

    public init(userID: String, email: String, name: String?, token: String, issuedAt: Date = .now) {
        self.userID = userID
        self.email = email
        self.name = name
        self.token = token
        self.issuedAt = issuedAt
    }
}

/// One model the Guardian account may use.
public struct GuardianModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String?
    public var contextWindow: Int?
    /// Whether the plan allows unattended work (the queue, /goal) on this model.
    public var interactiveOnly: Bool?

    public init(id: String, label: String? = nil, contextWindow: Int? = nil, interactiveOnly: Bool? = nil) {
        self.id = id
        self.label = label
        self.contextWindow = contextWindow
        self.interactiveOnly = interactiveOnly
    }
}

public enum GuardianError: LocalizedError, Equatable {
    case badURL
    case invalidCredentials(String)
    /// The account has TOTP 2FA on: finish with `verifyTwoFactor`.
    case twoFactorRequired(String)
    case unauthorized
    case server(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badURL:
            "That doesn't look like a Guardian address — it should be https://guardian.503cm.com (or your own deployment)."
        case .invalidCredentials(let detail):
            "Guardian didn't accept that sign-in. \(detail)"
        case .twoFactorRequired:
            "This Guardian account uses two-factor sign-in. Enter the 6-digit code from your authenticator app."
        case .unauthorized:
            "The Guardian sign-in has expired — sign in again to keep using it."
        case .server(let detail):
            "Guardian had a problem: \(detail)"
        case .network(let detail):
            "Couldn't reach Guardian: \(detail)"
        }
    }
}

/// The Guardian harness API client. The HTTP layer is pluggable so tests can
/// script responses.
public final class GuardianClient: @unchecked Sendable {
    /// The deployment's base address, e.g. https://guardian.503cm.com
    public let baseURL: URL
    public private(set) var session: GuardianSession?

    public typealias Transport = @Sendable (URLRequest) async throws -> (data: Data, status: Int)
    private let transport: Transport

    public init(baseURL: String, session: GuardianSession? = nil, transport: Transport? = nil) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw GuardianError.badURL
        }
        self.baseURL = url
        self.session = session
        self.transport = transport ?? Self.urlSessionTransport()
    }

    private static func urlSessionTransport() -> Transport {
        let closure: Transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return closure
    }

    public var isSignedIn: Bool { session != nil }

    // MARK: Auth

    /// Sign in with the Guardian login. A TOTP account throws
    /// `.twoFactorRequired(challenge)` — finish with `verifyTwoFactor`.
    public func signIn(email: String, password: String) async throws -> GuardianSession {
        struct Body: Encodable { var email: String; var password: String; var client: String }
        let issued = Date()
        let data = try await post(path: "/api/auth/login", body: Body(email: email, password: password, client: "dsh-mac"),
                                  token: nil)
        struct Response: Decodable {
            struct User: Decodable { var id: String?; var userId: String?; var email: String?; var name: String? }
            var token: String?
            var accessToken: String?
            var sessionToken: String?
            var user: User?
            var session: User?
            var id: String?
            var email: String?
            var name: String?
            var error: String?
            var message: String?
            var twoFactorRequired: Bool?
            var challenge: String?
        }
        let decoded = try? Self.decoder.decode(Response.self, from: data)
        if decoded?.twoFactorRequired == true, let challenge = decoded?.challenge, !challenge.isEmpty {
            throw GuardianError.twoFactorRequired(challenge)
        }
        guard let token = decoded?.token ?? decoded?.accessToken ?? decoded?.sessionToken, !token.isEmpty else {
            if let detail = decoded?.error ?? decoded?.message {
                throw GuardianError.invalidCredentials(detail)
            }
            throw GuardianError.invalidCredentials("Check the email and password.")
        }
        let user = decoded?.user ?? decoded?.session
        let newSession = GuardianSession(
            userID: user?.id ?? user?.userId ?? decoded?.id ?? email,
            email: user?.email ?? decoded?.email ?? email,
            name: user?.name ?? decoded?.name,
            token: token, issuedAt: issued)
        session = newSession
        return newSession
    }

    /// Finish a 2FA sign-in with the authenticator code.
    public func verifyTwoFactor(challenge: String, code: String) async throws -> GuardianSession {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else {
            throw GuardianError.invalidCredentials("The 2FA code is the 6-digit number from your authenticator app.")
        }
        struct Body: Encodable { var challenge: String; var code: String }
        let issued = Date()
        let data: Data
        do {
            data = try await post(path: "/api/auth/login/2fa", body: Body(challenge: challenge, code: trimmed), token: nil)
        } catch GuardianError.unauthorized {
            throw GuardianError.invalidCredentials(
                "Guardian didn't accept that code — it may have rotated. Codes refresh every 30 seconds.")
        }
        struct Response: Decodable {
            struct User: Decodable { var id: String?; var userId: String?; var email: String?; var name: String?; var uid: String? }
            var token: String?
            var session: User?
            var error: String?
            var message: String?
        }
        let decoded = try? Self.decoder.decode(Response.self, from: data)
        guard let token = decoded?.token, !token.isEmpty else {
            let detail = decoded?.error ?? decoded?.message ?? "Check the code and try again."
            throw GuardianError.invalidCredentials(detail)
        }
        let user = decoded?.session
        let newSession = GuardianSession(
            userID: user?.id ?? user?.userId ?? user?.uid ?? session?.email ?? "",
            email: user?.email ?? session?.email ?? "",
            name: user?.name ?? session?.name,
            token: token, issuedAt: issued)
        session = newSession
        return newSession
    }

    public func signOut() { session = nil }

    // MARK: Models (the proxy)

    /// What the Guardian account may run, through the proxy.
    public func models() async throws -> [GuardianModel] {
        struct Response: Decodable {
            struct Model: Decodable {
                var id: String
                var label: String?
                var contextWindow: Int?
                var interactiveOnly: Bool?
            }
            var models: [Model]?
            struct Data_: Decodable { var id: String }
            var `data`: [Data_]?
        }
        let data = try await get(path: "/api/harness/v1/models")
        let decoded = try Self.decoder.decode(Response.self, from: data)
        if let models = decoded.models {
            return models.map { GuardianModel(id: $0.id, label: $0.label, contextWindow: $0.contextWindow,
                                              interactiveOnly: $0.interactiveOnly) }
        }
        return (decoded.data ?? []).map { GuardianModel(id: $0.id) }
    }

    // MARK: Wire helpers

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let iso = ISO8601DateFormatter()
            let fractions = ISO8601DateFormatter()
            fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractions.date(from: raw) ?? iso.date(from: raw) { return date }
            if let seconds = TimeInterval(raw) { return Date(timeIntervalSince1970: seconds) }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unreadable date \(raw)")
        }
        return d
    }()

    private static let encoder = JSONEncoder()

    private func get(path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let token = session?.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let response = try await transport(request)
        try Self.check(response.status, data: response.data)
        return response.data
    }

    private func post<B: Encodable>(path: String, body: B, token: String?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try Self.encoder.encode(body)
        let response = try await transport(request)
        try Self.check(response.status, data: response.data)
        return response.data
    }

    static func check(_ status: Int, data: Data) throws {
        guard !(200...299).contains(status) else { return }
        struct Body: Decodable { var error: String?; var message: String? }
        let detail = (try? JSONDecoder().decode(Body.self, from: data)).flatMap { $0.error ?? $0.message }
        switch status {
        case 401, 403: throw GuardianError.unauthorized
        case 400, 422: throw GuardianError.invalidCredentials(detail ?? "The request was refused.")
        default: throw GuardianError.server(detail ?? "HTTP \(status)")
        }
    }
}

// MARK: - Guardian as routes

extension GuardianClient {
    /// The harness v1 endpoint as an OpenAI-compatible base URL.
    public var harnessAPIBase: String {
        baseURL.absoluteString + "/api/harness/v1"
    }

    /// One provider profile per allowed model. The API key is deliberately
    /// left empty — the app stores the token in the Keychain keyed by route
    /// ID, so it never lands in the preferences file.
    public func routes(for models: [GuardianModel]) -> [ProviderProfile] {
        models.map { model in
            ProviderProfile(kind: .guardian, name: "Guardian", baseURL: harnessAPIBase,
                            model: model.id, contextWindow: model.contextWindow)
        }
    }
}
