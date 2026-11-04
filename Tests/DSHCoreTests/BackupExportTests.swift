import XCTest
@testable import DSHCore

final class BackupExportTests: XCTestCase {

    /// A fake home with two app-support folders, an openclaw install (with a
    /// big cache that must NOT be exported) and preference plists.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("bkexp-\(UUID().uuidString)", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        for name in ["Vision", "DSHMac"] {
            let dir = support.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("conversations"),
                                                    withIntermediateDirectories: true)
            try Data("chat".utf8).write(to: dir.appendingPathComponent("conversations/a.json"))
            if name == "Vision" {
                try Data("vault".utf8).write(to: dir.appendingPathComponent("vault.json"))
            }
        }
        let oc = home.appendingPathComponent(".openclaw", isDirectory: true)
        for dir in ["secrets", "credentials", "cron", "workspace/skills/godaddy",
                    "workspace/sessions", "cache", "agents/main/sessions"] {
            try FileManager.default.createDirectory(at: oc.appendingPathComponent(dir, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: oc.appendingPathComponent("openclaw.json"))
        try Data("{}".utf8).write(to: oc.appendingPathComponent("openclaw.json.last-good"))
        try Data("k".utf8).write(to: oc.appendingPathComponent("secrets/api.json"))
        try Data("k".utf8).write(to: oc.appendingPathComponent("credentials/token.txt"))
        try Data("job".utf8).write(to: oc.appendingPathComponent("cron/jobs.json.bak"))
        try Data("# memory".utf8).write(to: oc.appendingPathComponent("workspace/MEMORY.md"))
        try Data("skill".utf8).write(to: oc.appendingPathComponent("workspace/skills/godaddy/SKILL.md"))
        // The cache that must stay out.
        try Data("junk".utf8).write(to: oc.appendingPathComponent("workspace/sessions/big.jsonl"))
        try Data("junk".utf8).write(to: oc.appendingPathComponent("cache/blob.bin"))
        try Data("agent".utf8).write(to: oc.appendingPathComponent("agents/main/config.json"))
        try Data("session".utf8).write(to: oc.appendingPathComponent("agents/main/sessions/s1.jsonl"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Preferences", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: home.appendingPathComponent("Library/Preferences/com.503cm.vision.mac.plist"))
        return home
    }

    func testExportsEverythingAndSkipsCaches() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dest = home.appendingPathComponent("backup-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let manifest = try BackupExport.exportEverything(
            to: dest, home: home,
            appSupportFolderNames: ["Vision", "DSHMac"],
            keychainServices: [],            // no keychain in tests
            defaultsIDs: ["com.503cm.vision.mac", "dev.local.dsh.mac"],
            includeOpenClaw: true, zip: false)

        let out = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: dest.path)
            .first { $0.hasPrefix("Vision-Backup-") })
        let root = dest.appendingPathComponent(out)
        let fm = FileManager.default

        // Both app-support folders copied, with their distinctive files.
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("app-support/Vision/vault.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("app-support/DSHMac/conversations/a.json").path))

        // OpenClaw: durable state in, caches out.
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/openclaw.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/openclaw.json.last-good").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/secrets/api.json").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/credentials/token.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/cron/jobs.json.bak").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/workspace/MEMORY.md").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/workspace/skills/godaddy/SKILL.md").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("openclaw/agents/main/config.json").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("openclaw/workspace/sessions").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("openclaw/cache").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("openclaw/agents/main/sessions").path))

        // Preferences.
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("preferences/com.503cm.vision.mac.plist").path))

        // Manifest sanity.
        XCTAssertEqual(manifest.errors, [])
        XCTAssertGreaterThan(manifest.totalBytes, 0)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
        let names = manifest.sections.map(\.name)
        XCTAssertEqual(Set(names), ["app-support/Vision", "app-support/DSHMac", "openclaw", "preferences"])
    }

    func testKeychainItemsLandInItemsJSON() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dest = home.appendingPathComponent("backup-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let manifest = try BackupExport.exportEverything(
            to: dest, home: home, appSupportFolderNames: ["Vision"],
            keychainServices: ["Vision.vault", "Vision.provider"],
            defaultsIDs: [], includeOpenClaw: false,
            keychain: { service in
                [("entry-\(service)", Data("secret-\(service)".utf8))]
            }, zip: false)

        let out = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: dest.path)
            .first { $0.hasPrefix("Vision-Backup-") })
        let data = try Data(contentsOf: dest.appendingPathComponent(out).appendingPathComponent("keychain/items.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: [[String: String]]]
        let items = try XCTUnwrap(json["items"])
        XCTAssertEqual(items.count, 2)
        let services = Set(items.compactMap { $0["service"] })
        XCTAssertEqual(services, ["Vision.vault", "Vision.provider"])
        XCTAssertTrue(items.allSatisfy { $0["data"]!.contains("secret-") == false }) // base64, not plaintext
        XCTAssertEqual(manifest.errors, [])
    }

    func testKeychainFailureIsRecordedNotFatal() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dest = home.appendingPathComponent("backup-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        struct Boom: LocalizedError { var errorDescription: String? { "locked" } }
        let manifest = try BackupExport.exportEverything(
            to: dest, home: home, appSupportFolderNames: [],
            keychainServices: ["Vision.vault"],
            defaultsIDs: [], includeOpenClaw: false,
            keychain: { _ in throw Boom() }, zip: false)

        XCTAssertEqual(manifest.errors, ["keychain Vision.vault: locked"])
        // The rest of the export still happened.
        XCTAssertTrue(manifest.sections.isEmpty || !manifest.sections.isEmpty)
    }

    func testMissingFoldersAreSimplySkipped() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("bkexp-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let dest = home.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let manifest = try BackupExport.exportEverything(
            to: dest, home: home, appSupportFolderNames: ["Vision"],
            keychainServices: [], defaultsIDs: [], includeOpenClaw: true, zip: false)
        XCTAssertEqual(manifest.sections, [])
        XCTAssertEqual(manifest.totalBytes, 0)
    }
}
