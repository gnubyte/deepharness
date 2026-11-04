import Foundation
import Security
import DSHCore

/// The harness's Guardian connection: sign in (email + password, + a TOTP
/// step for 2FA accounts), then present every model the account may use as a
/// normal provider route.
///
/// Routes live in `AppConfig.providers` like any other — which is exactly why
/// a local DGX Spark model can never clobber a Guardian selection and vice
/// versa: they are independent entries. Switching the main model to the Spark
/// leaves the Guardian routes configured (the model menu shows them under
/// "Guardian"), and either can lead while the other takes subagent work.
///
/// The bearer token is stored in the Keychain under this app's own service,
/// keyed "token"/"email"/"address" — never in the preferences file, and never
/// inside a persisted route.
@MainActor
@Observable
public final class GuardianService {
    public static let defaultURL = "https://guardian.503cm.com"
    private static let keychainService = "DSHMac.guardian"
    /// The route name Guardian models share (routeID = "Guardian|<model>").
    public static let routeName = "Guardian"

    public private(set) var accountEmail: String?
    public private(set) var lastError: String?
    /// Set when a sign-in stopped at the 2FA step; the settings UI collects
    /// the authenticator code and calls `verifyTwoFactor(code:)`.
    public private(set) var pendingTwoFactorChallenge: String?
    public private(set) var pendingTwoFactorEmail: String?
    /// While the model list is being refreshed after a sign-in.
    public private(set) var isRefreshing = false

    private var client: GuardianClient?
    private let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
        let address = Self.read("address") ?? Self.defaultURL
        if let token = Self.read("token"), !token.isEmpty {
            let email = Self.read("email") ?? ""
            client = try? GuardianClient(baseURL: address.isEmpty ? Self.defaultURL : address,
                                         session: GuardianSession(userID: email, email: email,
                                                                  name: nil, token: token))
            accountEmail = email.isEmpty ? nil : email
            // Routes for the stored token: refresh quietly in the background —
            // if the token expired, sign-in is offered, not forced.
            Task { [weak self] in await self?.refreshModels(silent: true) }
        }
    }

    public var isSignedIn: Bool { client != nil && accountEmail != nil }
    public var address: String { Self.read("address") ?? Self.defaultURL }

    // MARK: Sign in / out

    /// Returns true when signed in; false when the flow needs a 2FA code
    /// (`pendingTwoFactorChallenge != nil`) or failed (`lastError != nil`).
    public func signIn(address: String, email: String, password: String) async -> Bool {
        lastError = nil
        pendingTwoFactorChallenge = nil
        pendingTwoFactorEmail = nil
        do {
            let guardian = try GuardianClient(baseURL: address)
            let session: GuardianSession
            do {
                session = try await guardian.signIn(email: email, password: password)
            } catch GuardianError.twoFactorRequired(let challenge) {
                // Hold the half-built client until the authenticator code
                // completes the flow in `verifyTwoFactor`.
                pendingClient = guardian
                pendingTwoFactorChallenge = challenge
                pendingTwoFactorEmail = email
                return false
            }
            try completeSignIn(guardian, session: session, address: address)
            await refreshModels()
            return true
        } catch {
            lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func verifyTwoFactor(code: String) async -> Bool {
        lastError = nil
        guard let guardian = pendingClient, let challenge = pendingTwoFactorChallenge else {
            lastError = "No 2FA sign-in is waiting for a code — sign in again."
            return false
        }
        return await finishTwoFactor(guardian, challenge: challenge, code: code)
    }

    private func finishTwoFactor(_ guardian: GuardianClient, challenge: String, code: String) async -> Bool {
        do {
            let session = try await guardian.verifyTwoFactor(challenge: challenge, code: code)
            pendingTwoFactorChallenge = nil
            pendingTwoFactorEmail = nil
            try completeSignIn(guardian, session: session, address: guardian.baseURL.absoluteString)
            await refreshModels()
            return true
        } catch {
            lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Abandon a sign-in waiting on its 2FA code.
    public func cancelTwoFactor() {
        pendingTwoFactorChallenge = nil
        pendingTwoFactorEmail = nil
        pendingClient = nil
        lastError = nil
    }

    @ObservationIgnored private var pendingClient: GuardianClient?

    private func completeSignIn(_ guardian: GuardianClient, session: GuardianSession, address: String) throws {
        Self.write(session.token, account: "token")
        Self.write(session.email, account: "email")
        Self.write(address, account: "address")
        client = guardian
        accountEmail = session.email
    }

    public func signOut() {
        Self.write(nil, account: "token")
        Self.write(nil, account: "email")
        client?.signOut()
        client = nil
        accountEmail = nil
        // Remove the Guardian routes; if one was the main model, the config
        // falls back to another route on its own.
        config.providers.removeAll { $0.kind == .guardian }
        if config.activeProvider == nil {
            config.activeRoute = config.providers.first?.routeID
        }
    }

    // MARK: Models → routes

    /// Ask Guardian what the account may run and (re)write one route per
    /// model. `silent` failures (an expired token at launch) leave the stored
    /// routes alone rather than tearing the selection down.
    public func refreshModels(silent: Bool = false) async {
        guard let guardian = client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let models = try await guardian.models()
            guard !models.isEmpty else {
                if !silent { lastError = "The Guardian account has no models available." }
                return
            }
            let fresh = guardian.routes(for: models)
            var providers = config.providers.filter { $0.kind != .guardian }
            providers.append(contentsOf: fresh)
            config.providers = providers
        } catch {
            if !silent {
                lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Keychain

    private static func write(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
