import Foundation

// MARK: - Bringing a backup into this install
//
// The other half of `BackupExport`: take the folder or zip one DSH/Vision wrote
// and restore it here. It may come from a differently named install, so every
// app-support home in the backup lands in this install's one home, and Keychain
// services are renamed to this install's.
//
// Before anything is overwritten, the current home is copied aside, so a bad
// import can be undone by hand. Files merge: a newer local file is kept.

public enum BackupImport {
    public enum Module: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        case chats, skills, memory, automations, otherData, settings, secrets, openClaw
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .chats: "Chats and archive"
            case .skills: "Skills"
            case .memory: "Memory"
            case .automations: "Automations and task queue"
            case .otherData: "Everything else in the data folder"
            case .settings: "Settings and model routes"
            case .secrets: "Secrets (API keys, vault, Guardian sign-in)"
            case .openClaw: "OpenClaw (~/.openclaw)"
            }
        }

        /// Top-level names in the data folder that belong to this module.
        var dataNames: Set<String> {
            switch self {
            case .chats: ["conversations", "archive"]
            case .skills: ["skills", "skill-drafts"]
            case .memory: ["MEMORY.md", "memory"]
            case .automations: ["automations.json", "task-queue.json"]
            default: []
            }
        }
    }

    public struct Contents: Sendable {
        public var root: URL
        public var manifest: BackupExport.Manifest?
        /// Backed-up data folders (Vision, DSHMac), in restore order.
        public var homes: [URL]
        public var keychainItems: Int
        public var preferenceFiles: [URL]
        public var hasOpenClaw: Bool
        /// Set when `root` is a temporary unzip the caller should remove.
        public var temporary: URL?
        public var available: Set<Module> {
            var out: Set<Module> = []
            if !homes.isEmpty { out.formUnion([.chats, .skills, .memory, .automations, .otherData]) }
            if !preferenceFiles.isEmpty { out.insert(.settings) }
            if keychainItems > 0 { out.insert(.secrets) }
            if hasOpenClaw { out.insert(.openClaw) }
            return out
        }
    }

    public struct Report: Sendable {
        public var filesCopied = 0
        public var filesKeptNewer = 0
        public var secretsRestored = 0
        public var settingsRestored = 0
        public var safetyCopy: URL?
        public var errors: [String] = []
    }

    public enum ImportError: LocalizedError {
        case notABackup
        case unzipFailed

        public var errorDescription: String? {
            switch self {
            case .notABackup: "That isn't a DSH or Vision backup: there's no manifest.json or app-support folder in it."
            case .unzipFailed: "The zip couldn't be opened."
            }
        }
    }

    public typealias KeychainWriter = @Sendable (_ service: String, _ account: String, _ data: Data) -> Bool

    // MARK: Inspect

    public static func inspect(_ location: URL) throws -> Contents {
        let fm = FileManager.default
        var folder = location
        var temporary: URL?
        if location.pathExtension.lowercased() == "zip" {
            let scratch = fm.temporaryDirectory.appendingPathComponent("dsh-import-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", location.path, scratch.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? fm.removeItem(at: scratch)
                throw ImportError.unzipFailed
            }
            temporary = scratch
            // The zip keeps its parent folder.
            let inner = (try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            folder = inner.first { $0.hasDirectoryPath } ?? scratch
        }
        let supportRoot = folder.appendingPathComponent("app-support", isDirectory: true)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) || fm.fileExists(atPath: supportRoot.path) else {
            if let temporary { try? fm.removeItem(at: temporary) }
            throw ImportError.notABackup
        }
        let found = ((try? fm.contentsOfDirectory(at: supportRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let prefsDir = folder.appendingPathComponent("preferences", isDirectory: true)
        let prefs = ((try? fm.contentsOfDirectory(at: prefsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Contents(root: folder,
                        manifest: (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(BackupExport.Manifest.self, from: $0) },
                        homes: found,
                        keychainItems: readKeychainItems(folder).count,
                        preferenceFiles: prefs,
                        hasOpenClaw: fm.fileExists(atPath: folder.appendingPathComponent("openclaw").path),
                        temporary: temporary)
    }

    private static func readKeychainItems(_ folder: URL) -> [[String: String]] {
        let url = folder.appendingPathComponent("keychain/items.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["items"] as? [[String: String]] ?? []
    }

    // MARK: Restore

    /// `Vision.provider` → `DSHMac.provider`, for an install called `DSHMac`.
    static func localService(_ service: String, homeName: String) -> String {
        guard let suffix = service.split(separator: ".", maxSplits: 1).dropFirst().first else { return service }
        return "\(homeName).\(suffix)"
    }

    /// Which module a top-level name in the data folder belongs to.
    static func module(forDataName name: String) -> Module {
        Module.allCases.first { $0.dataNames.contains(name) } ?? .otherData
    }

    /// `home` is this install's data folder. `defaults` receives the settings.
    @discardableResult
    public static func restore(_ contents: Contents, modules: Set<Module>, into home: URL,
                               defaults: UserDefaults = .standard,
                               homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                               keychain: KeychainWriter? = nil) throws -> Report {
        let fm = FileManager.default
        var report = Report()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // A copy of what's here now, before anything changes.
        if !modules.isDisjoint(with: [.chats, .skills, .memory, .automations, .otherData]) {
            let aside = home.deletingLastPathComponent()
                .appendingPathComponent("\(home.lastPathComponent)-before-import-\(BackupExport.folderStamp(.now))", isDirectory: true)
            try BackupExport.copyTree(from: home, to: aside)
            report.safetyCopy = aside
        }

        for backedUp in contents.homes {
            for entry in (try? fm.contentsOfDirectory(at: backedUp, includingPropertiesForKeys: nil)) ?? [] {
                guard modules.contains(module(forDataName: entry.lastPathComponent)) else { continue }
                merge(from: entry, to: home.appendingPathComponent(entry.lastPathComponent), report: &report)
            }
        }

        if modules.contains(.settings) {
            for file in contents.preferenceFiles {
                guard let dictionary = NSDictionary(contentsOf: file) as? [String: Any] else {
                    report.errors.append("Couldn't read \(file.lastPathComponent).")
                    continue
                }
                for (key, value) in dictionary where !isSystemPreference(key) {
                    defaults.set(value, forKey: key)
                    report.settingsRestored += 1
                }
            }
        }

        if modules.contains(.secrets) {
            let write = keychain ?? secItemWriter
            for item in readKeychainItems(contents.root) {
                guard let service = item["service"], let account = item["account"],
                      let encoded = item["data"], let data = Data(base64Encoded: encoded) else { continue }
                if write(localService(service, homeName: home.lastPathComponent), account, data) {
                    report.secretsRestored += 1
                } else {
                    report.errors.append("The Keychain refused \(service)/\(account).")
                }
            }
        }

        if modules.contains(.openClaw) {
            merge(from: contents.root.appendingPathComponent("openclaw", isDirectory: true),
                  to: homeDirectory.appendingPathComponent(".openclaw", isDirectory: true), report: &report)
        }
        return report
    }

    /// AppKit's and the system's own keys, which belong to the machine.
    static func isSystemPreference(_ key: String) -> Bool {
        ["NS", "Apple", "com.apple.", "AK", "WebKit"].contains { key.hasPrefix($0) }
    }

    /// Copy a tree; an existing file stays if it's the newer of the two.
    private static func merge(from source: URL, to destination: URL, report: inout Report) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                report.errors.append("Couldn't create \(destination.path): \(error.localizedDescription)")
                return
            }
            for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] {
                merge(from: source.appendingPathComponent(name), to: destination.appendingPathComponent(name), report: &report)
            }
            return
        }
        if fm.fileExists(atPath: destination.path) {
            let date: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
            if date(destination) > date(source) {
                report.filesKeptNewer += 1
                return
            }
            try? fm.removeItem(at: destination)
        }
        do {
            try fm.copyItem(at: source, to: destination)
            report.filesCopied += 1
        } catch {
            report.errors.append("Couldn't copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static let secItemWriter: KeychainWriter = { service, account, data in
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
