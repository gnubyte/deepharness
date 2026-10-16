import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The shield's custom terms — client and patient names — live in the Keychain, never only in the settings file,
/// and a Keychain that can't be read costs none of them.
@MainActor
final class ShieldTermsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        try await super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "vision.shieldterms.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    /// What the settings file says the terms are.
    private func fileTerms(_ store: UserDefaults) -> [String] {
        guard let data = store.data(forKey: "shield.v1"),
              let settings = try? JSONDecoder().decode(ShieldSettings.self, from: data) else { return [] }
        return settings.customTerms
    }

    private func keychainTerms(_ secrets: any SecretStore) -> [String]? {
        secrets.read(service: AppConfig.termsService, account: AppConfig.termsAccount).map(AppConfig.decodeTerms)
    }

    func testTermsLiveInTheKeychainNotTheSettingsFile() {
        let store = defaults(), secrets = MemorySecretStore()
        let config = AppConfig(defaults: store, secrets: secrets)
        config.shield.customTerms = ["Acme", "Project Bluebird"]
        XCTAssertEqual(fileTerms(store), [])
        XCTAssertEqual(keychainTerms(secrets), ["Acme", "Project Bluebird"])
        XCTAssertEqual(AppConfig(defaults: store, secrets: secrets).shield.customTerms, ["Acme", "Project Bluebird"],
                       "back on the next launch")
        config.shield.customTerms = []
        XCTAssertNil(keychainTerms(secrets), "none left behind")
    }

    func testAPlainTextListFromAnEarlierBuildMovesOverOnce() throws {
        let store = defaults(), secrets = MemorySecretStore()
        var earlier = ShieldSettings()
        earlier.customTerms = ["Acme"]
        earlier.ips = true
        store.set(try JSONEncoder().encode(earlier), forKey: "shield.v1")
        let config = AppConfig(defaults: store, secrets: secrets)
        XCTAssertEqual(config.shield.customTerms, ["Acme"])
        XCTAssertTrue(config.shield.ips, "the other settings stay in the file")
        XCTAssertEqual(fileTerms(store), [], "out of the settings file…")
        XCTAssertEqual(keychainTerms(secrets), ["Acme"], "…into the Keychain")
    }

    func testAKeychainThatCantBeReadCostsNoTerms() throws {
        let store = defaults()
        var earlier = ShieldSettings()
        earlier.customTerms = ["Acme"]
        store.set(try JSONEncoder().encode(earlier), forKey: "shield.v1")
        let config = AppConfig(defaults: store, secrets: LockedSecrets())
        XCTAssertEqual(config.shield.customTerms, ["Acme"], "the file's copy is used…")
        XCTAssertEqual(fileTerms(store), ["Acme"], "…and kept")
        config.shield.customTerms = ["Acme", "Bob"]
        XCTAssertEqual(fileTerms(store), ["Acme", "Bob"], "a change the Keychain can't take stays in the file")

        // The Keychain answers again: the file's list is the newer one, and moves over.
        let open = MemorySecretStore(["\(AppConfig.termsService)/\(AppConfig.termsAccount)": #"["Acme"]"#])
        let later = AppConfig(defaults: store, secrets: open)
        XCTAssertEqual(later.shield.customTerms, ["Acme", "Bob"])
        XCTAssertEqual(keychainTerms(open), ["Acme", "Bob"])
        XCTAssertEqual(fileTerms(store), [])
    }

    func testAKeychainThatCantBeReadIsNotWrittenOver() {
        let locked = LockedSecrets()
        let config = AppConfig(defaults: defaults(), secrets: locked)
        XCTAssertEqual(config.shield.customTerms, [])
        config.preset = PermissionPreset.plan.rawValue
        config.shield.ips = true
        XCTAssertFalse(locked.wrote, "no empty list written over terms it couldn't read")
    }
}

/// A Keychain that can't be read (locked, say) and doesn't keep what is written.
private final class LockedSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _wrote = false
    var wrote: Bool { lock.withLock { _wrote } }
    func read(service: String, account: String) -> String? { nil }
    func write(_ value: String?, service: String, account: String) { lock.withLock { _wrote = true } }
    func lookup(service: String, account: String) -> SecretLookup { .unavailable }
}
