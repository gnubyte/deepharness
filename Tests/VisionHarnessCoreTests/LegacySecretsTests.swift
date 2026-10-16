import XCTest
@testable import VisionHarnessCore

/// A secret store that can be told to fail like a real Keychain: refuse reads of a service (an access prompt the
/// user turned down), drop writes to a service (a write that didn't land), or refuse deletes. Counts reads.
private final class FakeKeychain: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var unreadable: Set<String> = []
    var unwritable: Set<String> = []
    var undeletable: Set<String> = []
    private(set) var reads: [String] = []

    init(_ initial: [String: String] = [:]) { values = initial }

    func lookup(service: String, account: String) -> SecretLookup {
        lock.withLock {
            reads.append(service)
            if unreadable.contains(service) { return .unavailable }
            return values["\(service)/\(account)"].map(SecretLookup.found) ?? .missing
        }
    }

    func read(service: String, account: String) -> String? {
        if case .found(let value) = lookup(service: service, account: account) { return value }
        return nil
    }

    func write(_ value: String?, service: String, account: String) {
        lock.withLock {
            if let value, !value.isEmpty {
                if !unwritable.contains(service) { values["\(service)/\(account)"] = value }
            } else if !undeletable.contains(service) {
                values["\(service)/\(account)"] = nil
            }
        }
    }

    func stored(_ service: String, _ account: String) -> String? { lock.withLock { values["\(service)/\(account)"] } }
    func readCount(_ service: String) -> Int { lock.withLock { reads.filter { $0 == service }.count } }
}

final class LegacySecretsTests: XCTestCase {
    private let new = AppIdentity.KeychainService.provider
    private let old = "DSHMac.provider"

    private func store(_ keychain: FakeKeychain, ledger: any LegacySecretLedger = MemoryLegacySecretLedger()) -> LegacyFallbackSecretStore {
        LegacyFallbackSecretStore(base: keychain, ledger: ledger)
    }

    func testTheOldServiceNamesArePinned() {
        // These name items already in users' Keychains: they must never change.
        XCTAssertEqual(AppIdentity.Legacy.keychainServices, [
            "Vision.provider": "DSHMac.provider",
            "Vision.shield": "DSHMac.shield",
            "Vision.sparkSwapper": "DSHMac.sparkSwapper",
            "Vision.vault": "DSHMac.vault",
        ])
        XCTAssertEqual([AppIdentity.KeychainService.provider, AppIdentity.KeychainService.shield,
                        AppIdentity.KeychainService.sparkSwapper, AppIdentity.KeychainService.vault],
                       ["Vision.provider", "Vision.shield", "Vision.sparkSwapper", "Vision.vault"])
    }

    func testASecretOnlyUnderTheOldNameComesOverAndTheOldItemGoes() {
        let keychain = FakeKeychain(["\(old)/Spark|qwen": "sk-123"])
        let secrets = store(keychain)
        XCTAssertEqual(secrets.lookup(service: new, account: "Spark|qwen"), .found("sk-123"))
        XCTAssertEqual(keychain.stored(new, "Spark|qwen"), "sk-123")
        XCTAssertNil(keychain.stored(old, "Spark|qwen"), "copied, read back, then the old item deleted")
        XCTAssertEqual(secrets.read(service: new, account: "Spark|qwen"), "sk-123")
    }

    func testTheNewNameWinsAndTheOldItemIsNotTouched() {
        let keychain = FakeKeychain(["\(new)/r": "new-key", "\(old)/r": "old-key"])
        XCTAssertEqual(store(keychain).read(service: new, account: "r"), "new-key")
        XCTAssertEqual(keychain.stored(old, "r"), "old-key")
        XCTAssertEqual(keychain.readCount(old), 0)
    }

    func testNoSecretUnderEitherNameIsMissingAndTheOldNameIsAskedOnlyOnce() {
        let keychain = FakeKeychain()
        let ledger = MemoryLegacySecretLedger()
        XCTAssertEqual(store(keychain, ledger: ledger).lookup(service: new, account: "local"), .missing)
        XCTAssertEqual(store(keychain, ledger: ledger).lookup(service: new, account: "local"), .missing)
        XCTAssertEqual(keychain.readCount(old), 1, "the ledger outlives the store (it is kept in the settings file)")
    }

    func testAnOldItemThatCantBeReadIsUnavailableNotMissingAndIsNotAskedAgainThisRun() {
        let keychain = FakeKeychain(["\(old)/r": "old-key"])
        keychain.unreadable = [old]
        let ledger = MemoryLegacySecretLedger()
        let secrets = store(keychain, ledger: ledger)
        XCTAssertEqual(secrets.lookup(service: new, account: "r"), .unavailable,
                       "a refused prompt is not \"there is no key\"")
        XCTAssertEqual(secrets.lookup(service: new, account: "r"), .unavailable)
        XCTAssertEqual(keychain.readCount(old), 1, "one refusal is not a prompt on every read")
        XCTAssertEqual(ledger.count, 0)
        XCTAssertEqual(keychain.stored(old, "r"), "old-key")

        // The next launch asks again, and this time it is allowed.
        keychain.unreadable = []
        XCTAssertEqual(store(keychain, ledger: ledger).lookup(service: new, account: "r"), .found("old-key"))
        XCTAssertNil(keychain.stored(old, "r"))
    }

    func testANewItemThatCantBeReadNeverFallsBackToTheOldOne() {
        let keychain = FakeKeychain(["\(old)/r": "old-key"])
        keychain.unreadable = [new]
        XCTAssertEqual(store(keychain).lookup(service: new, account: "r"), .unavailable)
        XCTAssertEqual(keychain.readCount(old), 0)
    }

    func testACopyThatDoesntReadBackKeepsTheOldItem() {
        let keychain = FakeKeychain(["\(old)/r": "old-key"])
        keychain.unwritable = [new]
        let ledger = MemoryLegacySecretLedger()
        XCTAssertEqual(store(keychain, ledger: ledger).lookup(service: new, account: "r"), .found("old-key"),
                       "the app still gets the key for this use")
        XCTAssertEqual(keychain.stored(old, "r"), "old-key")
        XCTAssertEqual(ledger.count, 0, "it is tried again next time")

        keychain.unwritable = []
        XCTAssertEqual(store(keychain, ledger: ledger).lookup(service: new, account: "r"), .found("old-key"))
        XCTAssertEqual(keychain.stored(new, "r"), "old-key")
        XCTAssertNil(keychain.stored(old, "r"))
    }

    func testSavingASecretRetiresTheOldOne() {
        let keychain = FakeKeychain(["\(old)/r": "old-key"])
        let secrets = store(keychain)
        secrets.write("typed-key", service: new, account: "r")
        XCTAssertEqual(keychain.stored(new, "r"), "typed-key")
        XCTAssertNil(keychain.stored(old, "r"))
        XCTAssertEqual(secrets.read(service: new, account: "r"), "typed-key")
    }

    func testADeletedSecretNeverComesBackFromTheOldName() {
        // The old item can't be deleted (its Keychain access belongs to the old app): it must still never return.
        let keychain = FakeKeychain(["\(old)/r": "old-key"])
        keychain.undeletable = [old]
        let ledger = MemoryLegacySecretLedger()
        let secrets = store(keychain, ledger: ledger)
        XCTAssertEqual(secrets.read(service: new, account: "r"), "old-key")
        XCTAssertEqual(keychain.stored(old, "r"), "old-key", "this Keychain refused the delete")

        secrets.write(nil, service: new, account: "r")
        XCTAssertEqual(secrets.lookup(service: new, account: "r"), .missing)
        XCTAssertEqual(store(keychain, ledger: ledger).lookup(service: new, account: "r"), .missing, "not on the next launch either")

        // Deleting before it ever came over works the same way.
        let fresh = FakeKeychain(["\(old)/s": "old-key"])
        fresh.undeletable = [old]
        let other = store(fresh)
        other.write("", service: new, account: "s")
        XCTAssertEqual(other.lookup(service: new, account: "s"), .missing)
    }

    func testServicesWithoutAnOldNamePassThrough() {
        let keychain = FakeKeychain(["Other.service/a": "x"])
        let secrets = store(keychain)
        XCTAssertEqual(secrets.read(service: "Other.service", account: "a"), "x")
        XCTAssertEqual(secrets.lookup(service: "Other.service", account: "b"), .missing)
        secrets.write(nil, service: "Other.service", account: "a")
        XCTAssertNil(keychain.stored("Other.service", "a"))
    }

    func testEveryServiceComesOver() {
        var initial: [String: String] = [:]
        for (_, legacy) in AppIdentity.Legacy.keychainServices { initial["\(legacy)/acct"] = "v-\(legacy)" }
        let keychain = FakeKeychain(initial)
        let secrets = store(keychain)
        for (current, legacy) in AppIdentity.Legacy.keychainServices {
            XCTAssertEqual(secrets.read(service: current, account: "acct"), "v-\(legacy)", current)
            XCTAssertNil(keychain.stored(legacy, "acct"), legacy)
        }
    }

    func testTheSettingsFileLedgerRemembersAcrossLaunches() {
        let name = "vision.test.ledger.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = DefaultsLegacySecretLedger(defaults: defaults)
        XCTAssertFalse(first.isSettled("Vision.provider\u{1F}r"))
        first.settle("Vision.provider\u{1F}r")
        first.settle("Vision.provider\u{1F}r")
        XCTAssertEqual(defaults.stringArray(forKey: DefaultsLegacySecretLedger.key), ["Vision.provider\u{1F}r"])
        XCTAssertTrue(DefaultsLegacySecretLedger(defaults: defaults).isSettled("Vision.provider\u{1F}r"))
        XCTAssertFalse(DefaultsLegacySecretLedger(defaults: defaults).isSettled("Vision.provider\u{1F}s"))
    }
}

/// A blob store that can refuse to load or to save.
private final class FakeBlob: SecretBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var failLoad = false
    var failSave = false
    var failDelete = false
    init(_ data: Data? = nil) { self.data = data }
    func load() throws -> Data? {
        try lock.withLock {
            if failLoad { throw VaultError.keychain(-25293) }
            return data
        }
    }
    func save(_ data: Data) throws {
        try lock.withLock {
            if failSave { throw VaultError.keychain(-61) }
            self.data = data
        }
    }
    func delete() throws {
        try lock.withLock {
            if failDelete { throw VaultError.keychain(-25244) }
            data = nil
        }
    }
    var stored: Data? { lock.withLock { data } }
}

final class LegacyVaultStoreTests: XCTestCase {
    private let secrets = Data(#"{"id-1":"s3cr3t"}"#.utf8)

    func testTheVaultOnlyUnderTheOldNameComesOverAndTheOldItemGoes() throws {
        let current = FakeBlob(), legacy = FakeBlob(secrets)
        let store = LegacyFallbackBlobStore(current: current, legacy: legacy)
        XCTAssertEqual(try store.load(), secrets)
        XCTAssertEqual(current.stored, secrets)
        XCTAssertNil(legacy.stored)
        XCTAssertEqual(try store.load(), secrets)
    }

    func testTheNewVaultWins() throws {
        let current = FakeBlob(Data("{}".utf8)), legacy = FakeBlob(secrets)
        XCTAssertEqual(try LegacyFallbackBlobStore(current: current, legacy: legacy).load(), Data("{}".utf8))
        XCTAssertEqual(legacy.stored, secrets)
    }

    func testAnOldVaultThatCantBeReadStaysLockedNotEmpty() {
        let legacy = FakeBlob(secrets)
        legacy.failLoad = true
        XCTAssertThrowsError(try LegacyFallbackBlobStore(current: FakeBlob(), legacy: legacy).load())
        XCTAssertEqual(legacy.stored, secrets)
    }

    func testACopyThatCantBeSavedKeepsTheOldVault() throws {
        let current = FakeBlob(), legacy = FakeBlob(secrets)
        current.failSave = true
        XCTAssertEqual(try LegacyFallbackBlobStore(current: current, legacy: legacy).load(), secrets)
        XCTAssertEqual(legacy.stored, secrets)
        XCTAssertNil(current.stored)
    }

    func testAnOldVaultThatCantBeDeletedIsHarmless() throws {
        let current = FakeBlob(), legacy = FakeBlob(secrets)
        legacy.failDelete = true
        let store = LegacyFallbackBlobStore(current: current, legacy: legacy)
        XCTAssertEqual(try store.load(), secrets)
        try store.save(Data("{}".utf8))
        XCTAssertEqual(try store.load(), Data("{}".utf8), "the new item is read first from now on")
    }

    func testTheVaultThroughTheOldItemKeepsEveryCredential() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vision-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = FakeBlob(), current = FakeBlob()
        let before = CredentialVault(directory: dir, store: legacy)
        let entry = try before.add(name: "OPENAI_API_KEY", value: "sk-live-1")
        XCTAssertNotNil(legacy.stored)

        let after = CredentialVault(directory: dir, store: LegacyFallbackBlobStore(current: current, legacy: legacy))
        XCTAssertEqual(try after.value(for: entry.id), "sk-live-1")
        XCTAssertNil(legacy.stored)
        XCTAssertNotNil(current.stored)
    }
}

final class AppIdentityTests: XCTestCase {
    func testTheNamesThisBuildUses() {
        XCTAssertEqual(AppIdentity.name, "Vision")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.503cm.vision.mac")
        XCTAssertEqual(AppIdentity.supportFolderName, "Vision")
        XCTAssertEqual(AppIdentity.projectFolderName, ".vision")
        XCTAssertEqual(AppIdentity.projectInstructionsFileName, "VISION.md")
        XCTAssertEqual(AppIdentity.terminalProgram, "Vision")
        XCTAssertEqual(AppIdentity.awsProfile, "vision-bedrock")
        XCTAssertEqual(AWSSignIn.defaultProfile, "vision-bedrock")
    }

    func testTheOldNamesArePinned() {
        // Each names something already on users' Macs or in their repos.
        XCTAssertEqual(AppIdentity.Legacy.bundleIdentifier, "dev.local.dsh.mac")
        XCTAssertEqual(AppIdentity.Legacy.supportFolderName, "DSHMac")
        XCTAssertEqual(AppIdentity.Legacy.projectFolderName, ".dsh")
        XCTAssertEqual(AppIdentity.Legacy.projectInstructionsFileName, "DSH.md")
        XCTAssertEqual(AppIdentity.Legacy.awsProfile, "dsh-bedrock")
    }

    func testUserAgentsNameVision() {
        XCTAssertTrue(AppIdentity.userAgent.hasPrefix("Vision/"), AppIdentity.userAgent)
        XCTAssertTrue(AppIdentity.userAgent.hasSuffix(" (macOS)"), AppIdentity.userAgent)
        XCTAssertTrue(AppIdentity.bedrockUserAgent.hasPrefix("Vision-Mac/"), AppIdentity.bedrockUserAgent)
    }

    func testTheBundleScriptUsesTheSameIdentifier() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appendingPathComponent("bundle.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("<key>CFBundleIdentifier</key>      <string>\(AppIdentity.bundleIdentifier)</string>"))
        XCTAssertFalse(script.contains(AppIdentity.Legacy.bundleIdentifier))
    }

    func testTheBundleAndReleaseScriptsCallTheAppVision() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appendingPathComponent("bundle.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("<key>CFBundleName</key>            <string>\(AppIdentity.name)</string>"))
        XCTAssertTrue(script.contains("<key>CFBundleDisplayName</key>     <string>\(AppIdentity.name)</string>"))
        XCTAssertTrue(script.contains(#"APP="$ROOT/build/Vision.app""#))
        XCTAssertTrue(script.contains(#"cp "$BIN" "$APP/Contents/MacOS/Vision""#))
        XCTAssertTrue(script.contains(#"DMG="$ROOT/build/Vision.dmg""#))
        XCTAssertTrue(script.contains(#"hdiutil create -volname "Vision""#))
        let release = try String(contentsOf: repo.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        XCTAssertTrue(release.contains("build/Vision.app/Contents/Info.plist"), "the version is read from the bundle bundle.sh makes")
        XCTAssertTrue(release.contains(#"echo "title=Vision for macOS v$FULL""#))
        XCTAssertEqual(release.components(separatedBy: "build/Vision.dmg").count - 1, 2, "kept as an artifact and attached to the release")
        for (name, text) in [("bundle.sh", script), ("release.yml", release)] {
            XCTAssertNil(text.range(of: #"\b(DSH|DeepHarness)\b"#, options: [.regularExpression, .caseInsensitive]), name)
        }
    }

    func testProjectFoldersAreWrittenNewAndReadBoth() {
        let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)
        XCTAssertEqual(AppPaths.projectFolder(project, "skills").path, "/tmp/p/.vision/skills")
        XCTAssertEqual(AppPaths.projectFolders(project, "agents").map(\.path), ["/tmp/p/.vision/agents", "/tmp/p/.dsh/agents"])
        XCTAssertEqual(SkillLocations.projectSkills(project).path, "/tmp/p/.vision/skills")
    }

    func testTheDataFolderIsTheNewOneUnlessOnlyTheOldOneHasData() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vision-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let current = base.appendingPathComponent("Vision", isDirectory: true)
        let legacy = base.appendingPathComponent("DSHMac", isDirectory: true)
        XCTAssertEqual(AppPaths.resolveSupport(in: base), current, "nothing yet")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(AppPaths.resolveSupport(in: base), legacy, "not brought over yet")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        XCTAssertEqual(AppPaths.resolveSupport(in: base), legacy, "a folder that isn't settled doesn't count")
        try DataFolderMigration.writeMarker(.init(migratedFrom: legacy.path, at: .now), in: current)
        XCTAssertEqual(AppPaths.resolveSupport(in: base), current)
    }
}
