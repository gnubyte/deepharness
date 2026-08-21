import Foundation
import Security
import DSHCore

/// Persisted app configuration: providers, active model, permission preset,
/// recent projects, editor and terminal preferences. API keys are kept out of
/// the plist, in the Keychain, keyed by the provider's stable identity.
@MainActor
@Observable
public final class AppConfig {
    public static let shared = AppConfig()
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private enum Keys {
        static let providers = "providers.v2"
        static let activeModel = "activeModel.v2"
        static let preset = "permissionPreset.v1"
        static let recentProjects = "recentProjects.v1"
        static let wizardDone = "setupWizardCompleted.v1"
        static let editorFontSize = "editor.fontSize"
        static let editorWraps = "editor.wraps"
        static let editorLineNumbers = "editor.lineNumbers"
        static let terminalFontSize = "terminal.fontSize"
        static let terminalShell = "terminal.shell"
        static let lastMode = "workspace.mode"
    }

    private let defaults: UserDefaults
    /// Set while `load()` runs so the property observers don't write back.
    private var loading = false

    public var providers: [ProviderProfile] = [] {
        didSet { persist() }
    }
    /// Identity of the active route: `"<provider name>|<model>"`.
    public var activeRoute: String? {
        didSet { persist() }
    }
    /// A `PermissionPreset` raw value: workspaceWrite | plan | fullAccess.
    public var preset: String = PermissionPreset.workspaceWrite.rawValue {
        didSet { persist() }
    }
    public var recentProjects: [String] = [] {
        didSet { persist() }
    }
    public var wizardCompleted: Bool = false {
        didSet { if !loading { defaults.set(wizardCompleted, forKey: Keys.wizardDone) } }
    }

    // Editor / terminal preferences.
    public var editorFontSize: Double = 13 { didSet { persist() } }
    public var editorWraps: Bool = false { didSet { persist() } }
    public var editorLineNumbers: Bool = true { didSet { persist() } }
    public var terminalFontSize: Double = 12 { didSet { persist() } }
    public var terminalShell: String = "" { didSet { persist() } }
    /// "chat" or "code" — the workspace reopens where you left it.
    public var lastMode: String = "chat" { didSet { persist() } }

    // MARK: - Active route

    /// The provider/model pair the next session will use, with its API key
    /// filled in from the Keychain.
    public var activeProvider: ProviderProfile? {
        guard let activeRoute, let stored = providers.first(where: { $0.routeID == activeRoute })
        else { return nil }
        var resolved = stored
        let key = apiKey(for: stored)
        resolved.apiKey = key.isEmpty ? nil : key
        return resolved
    }

    public var isConfigured: Bool { activeProvider != nil }

    /// Make this provider the active route.
    public func activate(_ provider: ProviderProfile) {
        if let index = providers.firstIndex(where: { $0.routeID == provider.routeID }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        activeRoute = provider.routeID
    }

    public func removeProvider(_ provider: ProviderProfile) {
        providers.removeAll { $0.routeID == provider.routeID }
        if activeRoute == provider.routeID { activeRoute = providers.first?.routeID }
    }

    /// The client to drive sessions with.
    /// Throws `LLMError.noModel` when nothing is configured, which the UI uses
    /// to route back to the setup wizard.
    public func makeClient() throws -> any LLMClient {
        guard let provider = activeProvider else { throw LLMError.noModel }
        return OpenAIClient(profile: provider)
    }

    public var asPreset: PermissionPreset {
        PermissionPreset(rawValue: preset) ?? .workspaceWrite
    }

    // MARK: - Keychain
    //
    // Keyed by the provider's stable identity rather than its position, so
    // reordering or deleting a provider never hands its key to another one.

    private static let keychainService = "DSHMac.provider"

    public func setAPIKey(_ key: String, for provider: ProviderProfile) {
        let account = provider.routeID
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public func apiKey(for provider: ProviderProfile) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: provider.routeID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Projects

    /// Record a folder as recently opened (newest first, capped).
    public func touchProject(_ path: String) {
        recentProjects.removeAll { $0 == path }
        recentProjects.insert(path, at: 0)
        if recentProjects.count > 12 { recentProjects = Array(recentProjects.prefix(12)) }
    }

    public func forgetProject(_ path: String) {
        recentProjects.removeAll { $0 == path }
    }

    /// Recent projects that still exist on disk.
    public var liveRecentProjects: [URL] {
        recentProjects
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Persistence

    private func load() {
        loading = true
        defer { loading = false }
        if let data = defaults.data(forKey: Keys.providers),
           let decoded = try? JSONDecoder().decode([ProviderProfile].self, from: data),
           !decoded.isEmpty {
            providers = decoded
        } else {
            providers = ProviderProfile.presets
        }
        activeRoute = defaults.string(forKey: Keys.activeModel)
        preset = defaults.string(forKey: Keys.preset) ?? PermissionPreset.workspaceWrite.rawValue
        recentProjects = defaults.stringArray(forKey: Keys.recentProjects) ?? []
        wizardCompleted = defaults.bool(forKey: Keys.wizardDone)
        editorFontSize = defaults.object(forKey: Keys.editorFontSize) as? Double ?? 13
        editorWraps = defaults.object(forKey: Keys.editorWraps) as? Bool ?? false
        editorLineNumbers = defaults.object(forKey: Keys.editorLineNumbers) as? Bool ?? true
        terminalFontSize = defaults.object(forKey: Keys.terminalFontSize) as? Double ?? 12
        terminalShell = defaults.string(forKey: Keys.terminalShell) ?? ""
        lastMode = defaults.string(forKey: Keys.lastMode) ?? "chat"
    }

    private func persist() {
        guard !loading else { return }
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Keys.providers)
        }
        defaults.set(activeRoute, forKey: Keys.activeModel)
        defaults.set(preset, forKey: Keys.preset)
        defaults.set(recentProjects, forKey: Keys.recentProjects)
        defaults.set(editorFontSize, forKey: Keys.editorFontSize)
        defaults.set(editorWraps, forKey: Keys.editorWraps)
        defaults.set(editorLineNumbers, forKey: Keys.editorLineNumbers)
        defaults.set(terminalFontSize, forKey: Keys.terminalFontSize)
        defaults.set(terminalShell, forKey: Keys.terminalShell)
        defaults.set(lastMode, forKey: Keys.lastMode)
    }
}

public extension ProviderProfile {
    /// Stable identity for a configured route: survives reordering, and two
    /// models on the same server stay distinct.
    var routeID: String { "\(name)|\(model)" }

    /// A local server needs no key and should not be nagged for one.
    var needsAPIKey: Bool {
        switch kind {
        case .ollama, .lmStudio: return false
        case .openAICompat: return !isLoopbackOrLAN
        case .openAI, .openRouter: return true
        }
    }

    var isLoopbackOrLAN: Bool {
        guard let host = URL(string: baseURL)?.host else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if host.hasPrefix("172.") {
            let second = host.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 0
            return (16...31).contains(second)
        }
        return false
    }

    var displayName: String { "\(name) · \(model)" }
}
