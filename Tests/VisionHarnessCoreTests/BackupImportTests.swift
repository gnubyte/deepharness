import XCTest
@testable import VisionHarnessCore

final class BackupImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ text: String, _ path: String, under base: URL, date: Date? = nil) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    /// A real backup, written by the real exporter from a fake home.
    private func makeBackup(zip: Bool = false) throws -> URL {
        let home = root.appendingPathComponent("oldmac", isDirectory: true)
        let vision = home.appendingPathComponent("Library/Application Support/Vision", isDirectory: true)
        try put("{}", "conversations/a.json", under: vision)
        try put("skill", "skills/x/SKILL.md", under: vision)
        try put("- fact", "MEMORY.md", under: vision)
        try put("[]", "automations.json", under: vision)
        try put("v", "vault.json", under: vision)
        try put("{}", "cron/jobs.json", under: home.appendingPathComponent(".openclaw"))
        let prefs = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["editor.fontSize": 17.0, "NSWindow Frame": "x"], format: .xml, options: 0)
        try plist.write(to: prefs.appendingPathComponent("com.503cm.vision.mac.plist"))
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let manifest = try BackupExport.exportEverything(
            to: out, home: home, keychain: { service in service == "Vision.provider" ? [("route", Data("key".utf8))] : [] }, zip: zip)
        if zip, let name = manifest.zippedPath { return out.appendingPathComponent(name) }
        let folder = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first { $0.hasDirectoryPath }
        return try XCTUnwrap(folder)
    }

    private func defaults() -> UserDefaults {
        let name = "imp-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testInspectFindsWhatIsThere() throws {
        let contents = try BackupImport.inspect(makeBackup())
        XCTAssertEqual(contents.homes.map(\.lastPathComponent), ["Vision"])
        XCTAssertEqual(contents.keychainItems, 1)
        XCTAssertEqual(contents.available, Set(BackupImport.Module.allCases))
    }

    func testAZipWorksToo() throws {
        let contents = try BackupImport.inspect(makeBackup(zip: true))
        XCTAssertEqual(contents.homes.map(\.lastPathComponent), ["Vision"])
        XCTAssertNotNil(contents.temporary)
        try? FileManager.default.removeItem(at: contents.temporary!)
    }

    func testARandomFolderIsNotABackup() throws {
        XCTAssertThrowsError(try BackupImport.inspect(root))
    }

    func testRestoreBringsAVisionBackupIntoThisInstallsHome() throws {
        let contents = try BackupImport.inspect(makeBackup())
        let home = root.appendingPathComponent("new/DSHMac", isDirectory: true)
        let suite = defaults()
        let written = Written()
        let report = try BackupImport.restore(contents, modules: Set(BackupImport.Module.allCases).subtracting([.openClaw]),
                                              into: home, defaults: suite, homeDirectory: root.appendingPathComponent("new"),
                                              keychain: { service, account, data in written.add(service, account, data); return true })
        let fm = FileManager.default
        for path in ["conversations/a.json", "skills/x/SKILL.md", "MEMORY.md", "automations.json", "vault.json"] {
            XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(suite.double(forKey: "editor.fontSize"), 17)
        XCTAssertNil(suite.object(forKey: "NSWindow Frame"), "window state belongs to the machine")
        XCTAssertEqual(written.items.first?.0, "DSHMac.provider", "the service is renamed for this install")
        XCTAssertEqual(report.secretsRestored, 1)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("new/.openclaw").path))
    }

    func testOnlyTheChosenModulesComeOver() throws {
        let contents = try BackupImport.inspect(makeBackup())
        let home = root.appendingPathComponent("new/DSHMac", isDirectory: true)
        let suite = defaults()
        try BackupImport.restore(contents, modules: [.skills], into: home, defaults: suite, keychain: { _, _, _ in XCTFail("no secrets"); return true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("skills/x/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("conversations").path))
        XCTAssertNil(suite.object(forKey: "editor.fontSize"))
    }

    func testANewerLocalFileIsKeptAndTheOldDataIsSetAside() throws {
        let contents = try BackupImport.inspect(makeBackup())
        let home = root.appendingPathComponent("new/DSHMac", isDirectory: true)
        try put("newer local", "MEMORY.md", under: home, date: Date().addingTimeInterval(3600))
        let report = try BackupImport.restore(contents, modules: [.memory], into: home, defaults: defaults())
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("MEMORY.md"), encoding: .utf8), "newer local")
        XCTAssertEqual(report.filesKeptNewer, 1)
        let aside = try XCTUnwrap(report.safetyCopy)
        XCTAssertEqual(try String(contentsOf: aside.appendingPathComponent("MEMORY.md"), encoding: .utf8), "newer local")
    }

    func testAnOlderLocalFileIsReplaced() throws {
        let contents = try BackupImport.inspect(makeBackup())
        let home = root.appendingPathComponent("new/DSHMac", isDirectory: true)
        try put("stale", "MEMORY.md", under: home, date: Date().addingTimeInterval(-3600))
        try BackupImport.restore(contents, modules: [.memory], into: home, defaults: defaults())
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("MEMORY.md"), encoding: .utf8), "- fact")
    }

    func testTheRealKeychainReaderReadsWhatTheWriterWrote() throws {
        let service = "DSHMacTests.\(UUID().uuidString)"
        addTeardownBlock {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        XCTAssertTrue(BackupImport.secItemWriter(service, "one", Data("1".utf8)))
        XCTAssertTrue(BackupImport.secItemWriter(service, "two", Data("2".utf8)))
        let read = try BackupExport.secItemReader(service).sorted { $0.account < $1.account }
        XCTAssertEqual(read.map(\.account), ["one", "two"])
        XCTAssertEqual(read.map(\.data), [Data("1".utf8), Data("2".utf8)])
    }

    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [(String, String, Data)] = []
        func add(_ service: String, _ account: String, _ data: Data) {
            lock.lock(); defer { lock.unlock() }
            items.append((service, account, data))
        }
    }
}
