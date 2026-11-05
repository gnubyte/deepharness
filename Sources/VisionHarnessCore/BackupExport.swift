import Foundation

/// Exports *everything* the harness holds — both of its app-support homes
/// (Vision's folder and the DSHMac folder from before the rename),
/// its keychain secrets, its preferences, and the durable parts of a
/// ~/.openclaw install (skills, memory, secrets, credentials, cron, config) —
/// into one timestamped folder (optionally zipped) ready for a thumb drive.
///
/// Deliberately excludes OpenClaw's multi-gigabyte caches (workspace sessions,
/// browser profile, npm, tmp, media, logs) — those are not state, they are
/// exhaust. Everything with restore value goes in.
public enum BackupExport {

    public struct Section: Codable, Hashable, Sendable {
        public var name: String
        public var files: Int
        public var bytes: Int
        public var note: String?
    }

    public struct Manifest: Codable, Hashable, Sendable {
        public var startedAt: Date
        public var finishedAt: Date?
        public var sections: [Section]
        public var errors: [String]
        public var totalBytes: Int64
        public var zippedPath: String?
    }

    /// Reads every generic-password item under one keychain service.
    /// In the app this is the app's own items (no prompt); tests inject a fake.
    public typealias KeychainReader = @Sendable (_ service: String) throws -> [(account: String, data: Data)]

    /// The default SecItem reader.
    public static let secItemReader: KeychainReader = { service in
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return [] }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "keychain read failed (status \(status))"])
        }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (account, data)
        }
    }

    /// Runs the export. Returns the manifest; the export folder sits under
    /// `destination` named `Vision-Backup-<timestamp>` (plus a `.zip`).
    @discardableResult
    public static func exportEverything(
        to destination: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSupportFolderNames: [String] = ["Vision", "DSHMac"],
        keychainServices: [String] = ["Vision.vault", "Vision.provider", "DSHMac.vault", "DSHMac.provider"],
        defaultsIDs: [String] = ["com.503cm.vision.mac", "dev.local.dsh.mac"],
        includeOpenClaw: Bool = true,
        keychain: KeychainReader? = nil,
        zip: Bool = true
    ) throws -> Manifest {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let stamp = Self.folderStamp(Date())
        let out = destination.appendingPathComponent("Vision-Backup-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var manifest = Manifest(startedAt: .now, finishedAt: nil, sections: [], errors: [], totalBytes: 0)
        var errors: [String] = []
        var sections: [Section] = []

        func record(_ name: String, _ dir: URL) {
            let (files, bytes) = Self.tally(dir)
            sections.append(Section(name: name, files: files, bytes: bytes, note: nil))
        }

        // 1) The harness's own data — every app-support home that exists.
        for name in appSupportFolderNames {
            let dir = support.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { continue }
            let target = out.appendingPathComponent("app-support/\(name)", isDirectory: true)
            try? Self.copyTree(from: dir, to: target)
            record("app-support/\(name)", target)
        }

        // 2) Keychain secrets (vault blobs + provider API keys).
        let reader = keychain ?? secItemReader
        var keychainItems: [[String: String]] = []
        var keychainServicesSeen = 0
        for service in keychainServices {
            do {
                let items = try reader(service)
                keychainServicesSeen += 1
                for item in items {
                    keychainItems.append([
                        "service": service,
                        "account": item.account,
                        "data": item.data.base64EncodedString(),
                    ])
                }
            } catch {
                errors.append("keychain \(service): \(error.localizedDescription)")
            }
        }
        if !keychainItems.isEmpty || keychainServicesSeen > 0 {
            let dir = out.appendingPathComponent("keychain", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let payload = try JSONSerialization.data(withJSONObject: ["items": keychainItems],
                                                     options: [.prettyPrinted, .sortedKeys])
            try payload.write(to: dir.appendingPathComponent("items.json"))
            record("keychain", dir)
        }

        // 3) Preferences plists for both bundle IDs.
        let prefsDir = out.appendingPathComponent("preferences", isDirectory: true)
        var prefsCopied = 0
        try fm.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        for id in defaultsIDs {
            let plist = home.appendingPathComponent("Library/Preferences/\(id).plist")
            if fm.fileExists(atPath: plist.path) {
                try? fm.copyItem(at: plist, to: prefsDir.appendingPathComponent("\(id).plist"))
                prefsCopied += 1
            }
        }
        if prefsCopied > 0 { record("preferences", prefsDir) }

        // 4) OpenClaw's durable state (selective — never the caches).
        if includeOpenClaw {
            let oc = home.appendingPathComponent(".openclaw", isDirectory: true)
            if fm.fileExists(atPath: oc.path) {
                let ocOut = out.appendingPathComponent("openclaw", isDirectory: true)
                let plainDirs = ["secrets", "credentials", "service-env", "identity", "cron",
                                 "memory", "tasks", "flows", "plugin-skills", "extensions"]
                for name in plainDirs {
                    let dir = oc.appendingPathComponent(name, isDirectory: true)
                    guard fm.fileExists(atPath: dir.path) else { continue }
                    try? Self.copyTree(from: dir, to: ocOut.appendingPathComponent(name))
                }
                let plainFiles = ["openclaw.json", "openclaw.json.last-good",
                                  "config-journal-fingerprint.key", "exec-approvals.json.migrated-2026.8.1",
                                  "update-check.json.migrated"]
                for name in plainFiles {
                    let f = oc.appendingPathComponent(name)
                    if fm.fileExists(atPath: f.path) {
                        try? fm.copyItem(at: f, to: ocOut.appendingPathComponent(name))
                    }
                }
                // agents/: root files + per-agent config, never session payloads.
                let agents = oc.appendingPathComponent("agents", isDirectory: true)
                if fm.fileExists(atPath: agents.path) {
                    let agentsOut = ocOut.appendingPathComponent("agents")
                    try? fm.createDirectory(at: agentsOut, withIntermediateDirectories: true)
                    let rootFiles = (try? fm.contentsOfDirectory(atPath: agents.path)) ?? []
                    for entry in rootFiles {
                        let src = agents.appendingPathComponent(entry)
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: src.path, isDirectory: &isDir)
                        if !isDir.boolValue { try? fm.copyItem(at: src, to: agentsOut.appendingPathComponent(entry)) }
                    }
                    for agent in (try? fm.contentsOfDirectory(atPath: agents.path)) ?? [] {
                        let agentDir = agents.appendingPathComponent(agent, isDirectory: true)
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: agentDir.path, isDirectory: &isDir), isDir.boolValue,
                              let entries = try? fm.contentsOfDirectory(atPath: agentDir.path) else { continue }
                        let agentOut = agentsOut.appendingPathComponent(agent)
                        try? fm.createDirectory(at: agentOut, withIntermediateDirectories: true)
                        for entry in entries where entry.hasSuffix(".json") || entry.hasSuffix(".md") {
                            try? fm.copyItem(at: agentDir.appendingPathComponent(entry),
                                             to: agentOut.appendingPathComponent(entry))
                        }
                    }
                }
                // workspace/: root files + skills only.
                let workspace = oc.appendingPathComponent("workspace", isDirectory: true)
                if fm.fileExists(atPath: workspace.path) {
                    let wsOut = ocOut.appendingPathComponent("workspace")
                    try? fm.createDirectory(at: wsOut, withIntermediateDirectories: true)
                    for entry in (try? fm.contentsOfDirectory(atPath: workspace.path)) ?? [] {
                        let src = workspace.appendingPathComponent(entry)
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: src.path, isDirectory: &isDir)
                        if !isDir.boolValue {
                            try? fm.copyItem(at: src, to: wsOut.appendingPathComponent(entry))
                        } else if entry == "skills" {
                            try? Self.copyTree(from: src, to: wsOut.appendingPathComponent("skills"))
                        }
                    }
                }
                let (ocFiles, ocBytes) = Self.tally(ocOut)
                sections.append(Section(name: "openclaw", files: ocFiles,
                                        bytes: ocBytes, note: "durable state only (no caches)"))
            }
        }

        // 5) Manifest.
        manifest.sections = sections
        manifest.errors = errors
        manifest.totalBytes = sections.reduce(0) { $0 + Int64($1.bytes) }
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: out.appendingPathComponent("manifest.json"))

        // 6) Zip beside the folder (a thumb drive wants one file to drag).
        if zip {
            let zipURL = destination.appendingPathComponent("Vision-Backup-\(stamp).zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                           out.lastPathComponent, zipURL.lastPathComponent]
            p.currentDirectoryURL = destination
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0, fm.fileExists(atPath: zipURL.path) {
                manifest.zippedPath = zipURL.lastPathComponent
                if let updated = try? JSONEncoder().encode(manifest) {
                    try? updated.write(to: out.appendingPathComponent("manifest.json"))
                }
            }
        }
        manifest.finishedAt = .now
        return manifest
    }

    // MARK: - Helpers

    static func folderStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Recursive copy that tolerates unreadable files (records nothing; a
    /// backup should not fail because one cache file is locked).
    static func copyTree(from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        guard let entries = try? fm.contentsOfDirectory(atPath: from.path) else { return }
        for entry in entries {
            let src = from.appendingPathComponent(entry)
            let dst = to.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try? copyTree(from: src, to: dst)
            } else {
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    static func tally(_ dir: URL) -> (files: Int, bytes: Int) {
        let fm = FileManager.default
        var files = 0, bytes = 0
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        for case let url as URL in walker {
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            files += 1
            bytes += vals.fileSize ?? 0
        }
        return (files, bytes)
    }
}
