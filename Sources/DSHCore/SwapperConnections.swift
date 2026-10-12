import Foundation
import Security

// MARK: - Swapper connections
//
// The boxes running a Spark Swapper that DSH knows: a DGX Spark, a Strix Halo, more than one of each. A
// connection holds how to reach and sign in to one; the secret (an app token, or the login's password) lives in
// the Keychain under the connection's id, never in the settings file. Earlier builds knew a single Swapper
// ("Settings ▸ Spark"); `SwapperConnectionStore.load` moves it into the list on first launch, password included.

public struct SwapperConnection: Codable, Sendable, Equatable, Identifiable {
    /// How DSH signs in to the box.
    public enum Auth: Sendable, Equatable {
        /// An app token from a connection code (Swapper 2.0).
        case token
        /// The web page's username and the password (any Swapper).
        case login(username: String)
    }

    public var id: String
    /// "DGX Spark (spark-3f2a)" — the box's own name, which the user may change.
    public var name: String
    /// The Swapper's address, "https://<box>:8999".
    public var url: String
    /// "nvidia-gb10", "amd-strix-halo"; nil for a Swapper older than 2.0 (which only ran on a DGX Spark).
    public var platform: String?
    public var hostname: String?
    /// The Swapper version it last reported.
    public var version: String?
    /// "token" or "login" (see `auth`).
    public var authKind: String
    public var username: String?
    /// The certificate both the Swapper and its model front present (SHA-256, "3A:9F:…").
    public var pinnedFingerprint: String?
    /// The model API, "https://<box>:11443/v1" — every route with this base URL is served by the box.
    public var apiBase: String?
    /// Routes made for this box (route ids).
    public var linkedRoutes: [String]
    /// Moved over from an earlier build's single Swapper: its password may still be only under the old Keychain
    /// account (see `SwapperConnectionStore.secret`).
    public var migrated: Bool?

    public init(id: String = UUID().uuidString, name: String, url: String, platform: String? = nil,
                hostname: String? = nil, version: String? = nil, auth: Auth, pinnedFingerprint: String? = nil,
                apiBase: String? = nil, linkedRoutes: [String] = []) {
        self.id = id
        self.name = name
        self.url = url
        self.platform = platform
        self.hostname = hostname
        self.version = version
        switch auth {
        case .token: authKind = "token"; username = nil
        case .login(let user): authKind = "login"; username = user
        }
        self.pinnedFingerprint = pinnedFingerprint
        self.apiBase = apiBase
        self.linkedRoutes = linkedRoutes
    }

    public var auth: Auth {
        authKind == "token" ? .token : .login(username: username ?? "")
    }

    /// "DGX Spark", "Strix Halo".
    public var platformName: String { SwapperPlatform.displayName(platform) }

    /// The host the Swapper runs on.
    public var host: String? { URL(string: url)?.host?.lowercased() }

    /// Whether `route` is served by this box: it was made for it, its address is the box's model API, or — for a
    /// connection from before Swapper 2.0, whose model API isn't known — it is on the same host.
    public func serves(_ route: ProviderProfile) -> Bool {
        if linkedRoutes.contains(route.routeID) { return true }
        guard route.kind != .bedrock else { return false }
        if let apiBase { return Self.sameBase(apiBase, route.baseURL) }
        guard let host, let routeHost = URL(string: route.baseURL)?.host?.lowercased() else { return false }
        return host == routeHost
    }

    /// Two Swapper addresses name the same box (`spark.local:8999` and `https://spark.local:8999/` alike).
    public static func sameAddress(_ a: String, _ b: String) -> Bool {
        guard let left = SparkSwapperClient.normalizedURL(a), let right = SparkSwapperClient.normalizedURL(b) else { return false }
        return left.absoluteString.lowercased() == right.absoluteString.lowercased()
    }

    /// Two base URLs name the same endpoint (case and trailing slashes aside).
    public static func sameBase(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return key(a) == key(b)
    }
}

// MARK: - The secret store

/// Where secrets live: the Keychain in the app, memory in tests.
public protocol SecretStore: Sendable {
    func read(service: String, account: String) -> String?
    /// Store `value`, or delete the secret when it is nil or empty.
    func write(_ value: String?, service: String, account: String)
}

/// Generic passwords in the login Keychain.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func read(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String?, service: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Secrets in memory (tests).
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init(_ initial: [String: String] = [:]) { values = initial }

    public func read(service: String, account: String) -> String? {
        lock.withLock { values["\(service)/\(account)"] }
    }

    public func write(_ value: String?, service: String, account: String) {
        lock.withLock { values["\(service)/\(account)"] = (value?.isEmpty ?? true) ? nil : value }
    }
}

// MARK: - Loading, saving, moving the old setting over

public enum SwapperConnectionStore {
    /// The list, in UserDefaults.
    public static let listKey = "spark.connections.v1"
    /// Keychain service for the secrets; the account is the connection's id. (The single Swapper of earlier
    /// builds kept its password here too, under the account "login".)
    public static let keychainService = "DSHMac.sparkSwapper"

    /// Earlier builds' single Swapper.
    enum Legacy {
        static let url = "spark.swapper.url"
        static let user = "spark.swapper.user"
        static let pin = "spark.swapper.pin"
        static let account = "login"
    }

    /// The saved connections. The first time (no list saved yet), the single Swapper an earlier build was set up
    /// with becomes the first connection — its address, login, certificate and password, and the routes on its
    /// host — so nothing the user set up is lost. The old setting itself is left in place. Each entry is read on
    /// its own: one this build can't read is skipped here and kept as it is by `save`.
    public static func load(defaults: UserDefaults, secrets: any SecretStore,
                            routes: [ProviderProfile] = []) -> [SwapperConnection] {
        if let data = defaults.data(forKey: listKey) {
            return entries(data)?.compactMap(decode) ?? []
        }
        guard let migrated = migrateLegacy(defaults: defaults, secrets: secrets, routes: routes) else { return [] }
        save([migrated], defaults: defaults)
        return [migrated]
    }

    /// Save the list. Entries already stored that this build can't read (a damaged one, one from a later build)
    /// are kept as they were; a stored list that isn't readable at all is first copied aside
    /// (`spark.connections.v1.unreadable`), never just overwritten.
    public static func save(_ connections: [SwapperConnection], defaults: UserDefaults) {
        var list: [Any] = connections.compactMap { connection in
            (try? JSONEncoder().encode(connection)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        if let stored = defaults.data(forKey: listKey) {
            if let old = entries(stored) {
                list += old.filter { decode($0) == nil }
            } else if defaults.data(forKey: listKey + ".unreadable") == nil {
                defaults.set(stored, forKey: listKey + ".unreadable")
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: list) { defaults.set(data, forKey: listKey) }
    }

    /// The stored list's entries, raw; nil when it isn't a list at all.
    private static func entries(_ data: Data) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }

    private static func decode(_ entry: Any) -> SwapperConnection? {
        guard JSONSerialization.isValidJSONObject(entry), let data = try? JSONSerialization.data(withJSONObject: entry) else {
            return nil
        }
        return try? JSONDecoder().decode(SwapperConnection.self, from: data)
    }

    /// The connection for an earlier build's "Settings ▸ Spark", or nil when it was never set up. The routes on the
    /// Swapper's host are linked to it, so they keep following its switches whatever it later reports about itself.
    static func migrateLegacy(defaults: UserDefaults, secrets: any SecretStore,
                              routes: [ProviderProfile] = []) -> SwapperConnection? {
        let url = (defaults.string(forKey: Legacy.url) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let user = (defaults.string(forKey: Legacy.user) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (SparkSwapperClient.normalizedURL(url)?.host ?? URL(string: url)?.host ?? url).lowercased()
        let linked = routes.filter { $0.kind != .bedrock && URL(string: $0.baseURL)?.host?.lowercased() == host }.map(\.routeID)
        var connection = SwapperConnection(name: "\(SwapperPlatform.displayName(nil)) (\(host))", url: url,
                                           auth: .login(username: user),
                                           pinnedFingerprint: defaults.string(forKey: Legacy.pin),
                                           linkedRoutes: linked)
        connection.migrated = true
        if let password = secrets.read(service: keychainService, account: Legacy.account), !password.isEmpty {
            secrets.write(password, service: keychainService, account: connection.id)
        }
        return connection
    }

    /// The connection's token or password. One moved over from an earlier build falls back to the old account
    /// when its own is missing (copying it over may have failed — a locked Keychain at first launch, say), and
    /// copies it over then.
    public static func secret(for connection: SwapperConnection, secrets: any SecretStore) -> String {
        if let own = secrets.read(service: keychainService, account: connection.id), !own.isEmpty { return own }
        if connection.migrated == true, let old = secrets.read(service: keychainService, account: Legacy.account), !old.isEmpty {
            secrets.write(old, service: keychainService, account: connection.id)
            return old
        }
        return ""
    }

    public static func setSecret(_ value: String?, for connection: SwapperConnection, secrets: any SecretStore) {
        secrets.write(value, service: keychainService, account: connection.id)
    }

    /// The client for a connection, signed in with its secret.
    public static func client(for connection: SwapperConnection, secrets: any SecretStore) -> SparkSwapperClient? {
        guard let url = URL(string: connection.url.trimmingCharacters(in: .whitespaces)) else { return nil }
        let secret = secret(for: connection, secrets: secrets)
        let auth: SwapperAuth
        switch connection.auth {
        case .token: auth = .token(secret)
        case .login(let user): auth = .login(username: user, password: secret)
        }
        return SparkSwapperClient(baseURL: url, auth: auth, pinnedFingerprint: connection.pinnedFingerprint)
    }
}

// MARK: - Connecting a box

public enum SwapperConnect {
    /// Check a connection code: reach the Swapper with the code's certificate pinned — the certificate presented
    /// must be exactly that one; system trust isn't consulted — then read its status with the code's token.
    public static func check(_ code: SwapperConnectionCode) async throws -> SwapperStatus {
        let client = SparkSwapperClient(baseURL: code.swapperURL, auth: .token(code.token),
                                        pinnedFingerprint: code.fingerprint, pinMode: .pinOnly)
        return try await client.status()
    }

    /// The connection a code describes.
    public static func connection(for code: SwapperConnectionCode) -> SwapperConnection {
        SwapperConnection(name: code.name, url: code.swapperURL.absoluteString, platform: code.platform,
                          hostname: code.hostname, version: code.version, auth: .token,
                          pinnedFingerprint: code.fingerprint, apiBase: code.apiBase.absoluteString)
    }

    /// What signing in with an address and login came to.
    public enum LoginOutcome: Sendable, Equatable {
        /// The box's certificate isn't trusted yet: show the user this fingerprint, and sign in again with it
        /// pinned once they trust it. (Nothing was sent: the password never goes to a certificate nobody trusts.)
        case needsTrust(fingerprint: String)
        /// Signed in with the password (`secret`), which nothing has kept yet — see `keep`. `connect` is what a 2.0
        /// Swapper said about itself, `credentials` the model API an older one offers.
        case connected(SwapperConnection, secret: String, connect: SwapperConnectInfo?, credentials: SwapperCredentials?)
    }

    /// Sign in to a box with its address (a bare host or IP is fine: https and port 8999 are filled in) and the web
    /// page's login, and read what it says about itself. Nothing is made on the box yet: the app token comes when
    /// the connection is kept (`keep`), so a guide left halfway leaves nothing behind on the Swapper.
    public static func login(address: String, username: String, password: String,
                             pinned: String?) async throws -> LoginOutcome {
        guard let url = SparkSwapperClient.normalizedURL(address) else {
            throw SwapperError.transport("“\(address)” isn't an address. Use the one in your browser, like https://192.168.1.42:8999.")
        }
        let client = SparkSwapperClient(baseURL: url, auth: .login(username: username, password: password),
                                        pinnedFingerprint: pinned)
        do {
            try await client.login()
        } catch SwapperError.untrustedCertificate(let fingerprint) {
            return .needsTrust(fingerprint: fingerprint)
        }
        let host = url.host ?? address
        do {
            let info = try await client.connectInfo()
            let connection = SwapperConnection(
                name: info.displayName,
                url: url.absoluteString, platform: info.platform, hostname: info.hostname, version: info.version,
                auth: .login(username: username),
                pinnedFingerprint: CertificatePin.normalized(pinned) ?? CertificatePin.normalized(info.fingerprint),
                apiBase: info.apiBase)
            return .connected(connection, secret: password, connect: info, credentials: nil)
        } catch SwapperError.unsupported {
            let credentials = try? await client.credentials()
            let session = try? await client.sessionInfo()
            let connection = SwapperConnection(
                name: "\(SwapperPlatform.displayName(session?.platform)) (\(session?.hostname ?? host))",
                url: url.absoluteString, platform: session?.platform, hostname: session?.hostname,
                version: session?.version, auth: .login(username: username),
                pinnedFingerprint: CertificatePin.normalized(pinned), apiBase: credentials?.apiBase)
            return .connected(connection, secret: password, connect: nil, credentials: credentials)
        }
    }

    /// What to keep for a box signed in to with a password: on a Swapper 2.0 an app token labelled `label` ("DSH
    /// on Pat's MacBook"), kept instead of the password; an older Swapper, which has no tokens, keeps the password.
    public static func keep(_ connection: SwapperConnection, password: String,
                            label: String) async throws -> (connection: SwapperConnection, secret: String) {
        guard case .login(let username) = connection.auth else { return (connection, password) }
        guard let url = URL(string: connection.url) else { throw SwapperError.notConfigured }
        let client = SparkSwapperClient(baseURL: url, auth: .login(username: username, password: password),
                                        pinnedFingerprint: connection.pinnedFingerprint)
        do {
            let grant = try await client.createToken(label: label)
            var kept = connection
            kept.authKind = "token"
            kept.username = nil
            return (kept, grant.token)
        } catch SwapperError.unsupported {
            return (connection, password)
        }
    }

    /// "DSH on Pat's MacBook" — how the Swapper's token list names this app.
    public static func tokenLabel(computerName: String?) -> String {
        let name = computerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "DSH on this Mac" : "DSH on \(name)"
    }
}

// MARK: - /swap

/// What `/swap …` asks for, with several boxes: list them all, switch a model on one, or ask which box.
public enum SwapCommand: Equatable, Sendable {
    /// `/swap`: every box's models.
    case list
    /// Switch `box` (a connection id) to the model the user typed.
    case switchModel(box: String, model: String)
    /// A model was named but there are several boxes and none is behind the main model: ask which.
    case whichBox(model: String)
    /// No box is set up.
    case noBoxes

    /// `/swap <model>` acts on the box behind the main model (else the only box); `/swap <box> <model>` names a
    /// box by the start of its name (or host name) — the longest start that picks out exactly one box wins.
    public static func parse(_ arg: String?, boxes: [SwapperConnection], primaryBox: String?) -> SwapCommand {
        guard !boxes.isEmpty else { return .noBoxes }
        let text = (arg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .list }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 2 {
            for count in stride(from: words.count - 1, through: 1, by: -1) {
                let prefix = words[0..<count].joined(separator: " ").lowercased()
                let hits = boxes.filter { box in
                    box.name.lowercased().hasPrefix(prefix) || (box.hostname?.lowercased().hasPrefix(prefix) ?? false)
                        || (box.host?.hasPrefix(prefix) ?? false)
                }
                if hits.count == 1 {
                    return .switchModel(box: hits[0].id, model: words[count...].joined(separator: " "))
                }
            }
        }
        if let primaryBox, boxes.contains(where: { $0.id == primaryBox }) {
            return .switchModel(box: primaryBox, model: text)
        }
        if boxes.count == 1 { return .switchModel(box: boxes[0].id, model: text) }
        return .whichBox(model: text)
    }
}
