import Foundation
import Security

// MARK: - Keychain items an earlier build made
//
// Before the app was called Vision it kept its secrets under other Keychain services (`AppIdentity.Legacy`).
// Nothing is moved in bulk at launch: each secret comes over the first time the app needs it. Its new name is
// read first; when that has none, the old name is read, the value is written under the new name and read back,
// and only a copy that reads back the same lets the old item go. A Keychain that can't be read never counts as
// "there is none", so nothing is lost to a locked Keychain or a refused access prompt. No value is ever logged.

/// Remembers, across launches, which secrets no longer need the old Keychain name: the value came over, there was
/// none to bring, or the app has since written (or deleted) the secret itself. Once a secret is in it, the old item
/// is never read again — so a key the user deletes can't come back from a copy the old name still holds.
public protocol LegacySecretLedger: Sendable {
    func isSettled(_ key: String) -> Bool
    func settle(_ key: String)
}

/// The ledger in the app's settings file.
public final class DefaultsLegacySecretLedger: LegacySecretLedger, @unchecked Sendable {
    public static let key = "vision.keychain.legacySettled.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func isSettled(_ key: String) -> Bool {
        lock.withLock { (defaults.stringArray(forKey: Self.key) ?? []).contains(key) }
    }

    public func settle(_ key: String) {
        lock.withLock {
            var settled = defaults.stringArray(forKey: Self.key) ?? []
            guard !settled.contains(key) else { return }
            settled.append(key)
            defaults.set(settled, forKey: Self.key)
        }
    }
}

/// The ledger in memory (tests).
public final class MemoryLegacySecretLedger: LegacySecretLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Set<String> = []
    public init() {}
    public func isSettled(_ key: String) -> Bool { lock.withLock { settled.contains(key) } }
    public func settle(_ key: String) { _ = lock.withLock { settled.insert(key) } }
    public var count: Int { lock.withLock { settled.count } }
}

/// A secret store that also finds what an earlier build kept under the service's old name (see the top of the file).
public final class LegacyFallbackSecretStore: SecretStore, @unchecked Sendable {
    private let base: any SecretStore
    /// New service → the service it was called before.
    private let renamed: [String: String]
    private let ledger: any LegacySecretLedger
    /// Old items this run couldn't read (a refused access prompt): not asked for again until the next launch, so
    /// one refusal doesn't become a prompt every time a setting is read.
    private let lock = NSLock()
    private var unreadable: Set<String> = []

    public init(base: any SecretStore, renamed: [String: String] = AppIdentity.Legacy.keychainServices,
                ledger: any LegacySecretLedger) {
        self.base = base
        self.renamed = renamed
        self.ledger = ledger
    }

    private static func key(_ service: String, _ account: String) -> String { service + "\u{1F}" + account }

    public func read(service: String, account: String) -> String? {
        if case .found(let value) = lookup(service: service, account: account) { return value }
        return nil
    }

    public func lookup(service: String, account: String) -> SecretLookup {
        let current = base.lookup(service: service, account: account)
        guard current == .missing, let old = renamed[service] else { return current }
        let key = Self.key(service, account)
        if ledger.isSettled(key) { return .missing }
        if lock.withLock({ unreadable.contains(key) }) { return .unavailable }
        switch base.lookup(service: old, account: account) {
        case .missing:
            ledger.settle(key)
            return .missing
        case .unavailable:
            lock.withLock { _ = unreadable.insert(key) }
            return .unavailable
        case .found(let value):
            base.write(value, service: service, account: account)
            if base.lookup(service: service, account: account) == .found(value) {
                // The copy reads back: the new name holds it now, and the old item can go.
                ledger.settle(key)
                base.write(nil, service: old, account: account)
            }
            // Either way the app has the value for this use; an unverified copy leaves the old item to try again.
            return .found(value)
        }
    }

    public func write(_ value: String?, service: String, account: String) {
        base.write(value, service: service, account: account)
        guard let old = renamed[service] else { return }
        let deleting = value?.isEmpty ?? true
        if deleting || base.lookup(service: service, account: account) == .found(value!) {
            // What the user just saved (or deleted) is the truth from now on: the old copy must never be read again.
            ledger.settle(Self.key(service, account))
            base.write(nil, service: old, account: account)
        }
    }
}

/// The app's Keychain: Vision's services, with each secret an earlier build kept brought over when first needed.
public enum AppSecrets {
    public static let keychain: any SecretStore = LegacyFallbackSecretStore(
        base: KeychainSecretStore(), ledger: DefaultsLegacySecretLedger())
}

// MARK: - The vault's single item

/// The credential vault's store, finding the vault an earlier build kept under the old Keychain name: read the new
/// item; when there is none, read the old one, save it under the new name, read it back, and only then delete the
/// old one. An old item that can't be read throws (the vault stays locked, and nothing is written over it).
public struct LegacyFallbackBlobStore: SecretBlobStore {
    public let current: any SecretBlobStore
    public let legacy: any SecretBlobStore

    public init(current: any SecretBlobStore, legacy: any SecretBlobStore) {
        self.current = current
        self.legacy = legacy
    }

    /// The app's vault: `Vision.vault`, falling back to the item an earlier build made.
    public static var app: LegacyFallbackBlobStore {
        LegacyFallbackBlobStore(current: KeychainBlobStore(),
                                legacy: KeychainBlobStore(service: AppIdentity.Legacy.keychainServices[AppIdentity.KeychainService.vault]!))
    }

    public func load() throws -> Data? {
        if let data = try current.load() { return data }
        guard let data = try legacy.load() else { return nil }
        if (try? current.save(data)) != nil, (try? current.load()) == data {
            try? legacy.delete()
        }
        return data
    }

    public func save(_ data: Data) throws { try current.save(data) }

    public func delete() throws {
        try current.delete()
        try legacy.delete()
    }
}
