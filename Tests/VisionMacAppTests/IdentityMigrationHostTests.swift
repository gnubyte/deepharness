import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The move from the app's old name, end to end through the app's own stores: chats and the task queue written by
/// the app in the old data folder read back from the new one; keys, shield terms and Swapper passwords kept under
/// the old Keychain names reach the app's settings.
@MainActor
final class IdentityMigrationHostTests: XCTestCase {
    private var base: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vision-host-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults() -> UserDefaults {
        let suite = "vision.migrationhost.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    func testChatsAndTheQueueTheAppWroteInTheOldFolderReadBackFromTheNewOne() throws {
        let legacy = DataFolderMigration.legacyFolder(in: base)
        let current = DataFolderMigration.currentFolder(in: base)
        let plainScratch = legacy.appendingPathComponent("Chats/plain-1").path

        // The old build's stores, written the way the app writes them.
        let oldLog = ConversationLog(dir: legacy.appendingPathComponent("conversations"))
        oldLog.upsert(id: "plain-1", cwd: nil, title: "Plain", preset: "workspaceWrite")
        oldLog.upsert(id: "queued-1", cwd: nil, title: "🚀 Task", preset: "workspaceWrite", scratch: plainScratch)
        oldLog.upsert(id: "project-1", cwd: "/Users/pat/project", title: "Project", preset: "plan")
        oldLog.recordItem("queued-1", kind: "user", text: "Work in \(plainScratch)", toolName: nil, argSummary: nil,
                          output: nil, isError: false)
        oldLog.recordItem("queued-1", kind: "tool", text: nil, toolName: "write_file", argSummary: "notes.md",
                          output: "Wrote notes.md", isError: true)
        oldLog.flush(wait: true)
        let before = oldLog.loadItems("queued-1")

        var task = QueueTask(title: "Plain task", details: "Do it", cwd: nil)
        task.workFolder = plainScratch
        task.rounds = 3
        task.promptTokens = 1200
        task.startedAt = Date(timeIntervalSinceReferenceDate: 781_234_567.123_456)
        task.appendLog(.round, "Round 1", at: Date(timeIntervalSinceReferenceDate: 781_234_600.5))
        var queue = TaskQueue()
        queue.appendTask(task)
        try JSONEncoder().encode(queue).write(to: legacy.appendingPathComponent("task-queue.json"))

        guard case .migrated = DataFolderMigration.run(in: base) else { return XCTFail("not migrated") }

        let newLog = ConversationLog(dir: current.appendingPathComponent("conversations"))
        let sessions = Dictionary(uniqueKeysWithValues: newLog.list().map { ($0.id, $0) })
        XCTAssertEqual(Set(sessions.keys), ["plain-1", "queued-1", "project-1"])
        XCTAssertEqual(sessions["queued-1"]?.scratch, current.appendingPathComponent("Chats/plain-1").path)
        XCTAssertNil(sessions["plain-1"]?.scratch)
        XCTAssertEqual(sessions["project-1"]?.cwd, "/Users/pat/project")
        XCTAssertEqual(sessions["project-1"]?.preset, "plan")
        let after = newLog.loadItems("queued-1")
        XCTAssertEqual(after.count, 2)
        for (a, b) in zip(before, after) {
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(a.text, b.text, "what was said stays as it was said")
            XCTAssertEqual(a.toolName, b.toolName)
            XCTAssertEqual(a.output, b.output)
            XCTAssertEqual(a.isError, b.isError)
            XCTAssertEqual(a.at, b.at)
        }

        let moved = try JSONDecoder().decode(TaskQueue.self, from: Data(contentsOf: current.appendingPathComponent("task-queue.json")))
        let back = try XCTUnwrap(moved.tasks.first)
        XCTAssertEqual(back.workFolder, current.appendingPathComponent("Chats/plain-1").path)
        var expected = task
        expected.workFolder = back.workFolder
        XCTAssertEqual(back, expected, "everything else about the task is as it was")
    }

    func testKeysAndShieldTermsUnderTheOldKeychainNamesReachTheSettings() throws {
        let route = ProviderProfile(kind: .openAI, name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama")
        let keychain = MemorySecretStore([
            "DSHMac.provider/\(route.routeID)": "gsk-old",
            "DSHMac.shield/terms": #"["Acme","Project Bluebird"]"#,
        ])
        let secrets = LegacyFallbackSecretStore(base: keychain, ledger: MemoryLegacySecretLedger())
        let store = defaults()
        let config = AppConfig(defaults: store, secrets: secrets)
        XCTAssertEqual(config.shield.customTerms, ["Acme", "Project Bluebird"])
        XCTAssertEqual(config.apiKey(for: route), "gsk-old")
        XCTAssertEqual(keychain.read(service: "Vision.provider", account: route.routeID), "gsk-old")
        XCTAssertNil(keychain.read(service: "DSHMac.provider", account: route.routeID))
        XCTAssertEqual(keychain.read(service: "Vision.shield", account: "terms").map(AppConfig.decodeTerms),
                       ["Acme", "Project Bluebird"])
        XCTAssertNil(keychain.read(service: "DSHMac.shield", account: "terms"))

        // Back on the next launch, from the new names.
        let again = AppConfig(defaults: store, secrets: LegacyFallbackSecretStore(base: keychain, ledger: MemoryLegacySecretLedger()))
        XCTAssertEqual(again.apiKey(for: route), "gsk-old")
        XCTAssertEqual(again.shield.customTerms, ["Acme", "Project Bluebird"])
    }

    func testASwapperPasswordUnderTheOldKeychainNameStillSignsIn() {
        let store = defaults()
        store.set("https://spark.local:8999", forKey: "spark.swapper.url")
        store.set("pat", forKey: "spark.swapper.user")
        let keychain = MemorySecretStore(["DSHMac.sparkSwapper/login": "hunter2"])
        let secrets = LegacyFallbackSecretStore(base: keychain, ledger: MemoryLegacySecretLedger())

        let box = SwapperConnectionStore.load(defaults: store, secrets: secrets).first
        XCTAssertNotNil(box)
        if let box { XCTAssertEqual(SwapperConnectionStore.secret(for: box, secrets: secrets), "hunter2") }
        XCTAssertNil(keychain.read(service: "DSHMac.sparkSwapper", account: "login"))
    }

    // MARK: The launch, start to finish

    private func launch(_ own: String, legacyDomain: String, legacyAppIsClosed: () -> Bool = { true }) -> Bool {
        LaunchMigration.run(base: base, defaults: UserDefaults(suiteName: own)!, ownDomain: own,
                            legacyDomain: legacyDomain, legacyAppIsClosed: legacyAppIsClosed)
    }

    /// An earlier build's settings file and data folder, with a skill switched off by its path.
    private func seedEarlierBuild() throws -> (own: String, legacyDomain: String, skill: String) {
        let own = "vision.launch.own.\(UUID().uuidString)", legacyDomain = "vision.launch.legacy.\(UUID().uuidString)"
        suites += [own, legacyDomain]
        let legacy = DataFolderMigration.legacyFolder(in: base)
        let skill = legacy.appendingPathComponent("skills/alpha/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: alpha\ndescription: Use when alpha.\n---\n".utf8).write(to: skill)
        let old = UserDefaults(suiteName: legacyDomain)!
        old.set(true, forKey: "setupWizardCompleted.v1")
        old.set([skill.path], forKey: "skills.disabled.v1")
        return (own, legacyDomain, "skills/alpha/SKILL.md")
    }

    func testTheFirstLaunchBringsTheFolderAndSettingsOverAndPointsThemAtEachOther() throws {
        let (own, legacyDomain, skill) = try seedEarlierBuild()
        XCTAssertTrue(launch(own, legacyDomain: legacyDomain))
        XCTAssertNil(LaunchMigration.failure)

        let current = DataFolderMigration.currentFolder(in: base)
        let settings = UserDefaults(suiteName: own)!
        XCTAssertTrue(DataFolderMigration.isSettled(current))
        XCTAssertTrue(settings.bool(forKey: "setupWizardCompleted.v1"))
        XCTAssertEqual(settings.stringArray(forKey: "skills.disabled.v1"), [current.appendingPathComponent(skill).path],
                       "a switched-off skill stays off: its id is its path, now in the new folder")
        XCTAssertTrue(settings.bool(forKey: LegacySettingsImport.noticePendingKey))
        XCTAssertEqual(AppPaths.resolveSupport(in: base), current)

        // The next launch changes nothing.
        settings.removeObject(forKey: LegacySettingsImport.noticePendingKey)
        let before = settings.persistentDomain(forName: own) as NSDictionary?
        XCTAssertTrue(launch(own, legacyDomain: legacyDomain) { XCTFail("nothing to move: no need to ask"); return true })
        XCTAssertEqual(settings.persistentDomain(forName: own) as NSDictionary?, before)
    }

    func testWhenTheOldAppStaysOpenNothingIsTouched() throws {
        let (own, legacyDomain, _) = try seedEarlierBuild()
        XCTAssertFalse(launch(own, legacyDomain: legacyDomain) { false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: DataFolderMigration.currentFolder(in: base).path))
        XCTAssertNil(UserDefaults(suiteName: own)!.persistentDomain(forName: own)?[LegacySettingsImport.importedKey])
    }

    func testAFolderThatCantMoveYetKeepsTheSettingsPointingAtTheOldOneUntilItDoes() throws {
        let (own, legacyDomain, skill) = try seedEarlierBuild()
        let legacy = DataFolderMigration.legacyFolder(in: base)
        let locked = legacy.appendingPathComponent(skill).path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
        guard getuid() != 0 else { throw XCTSkip("root reads anything") }

        XCTAssertTrue(launch(own, legacyDomain: legacyDomain))
        XCTAssertNotNil(LaunchMigration.failure)
        let settings = UserDefaults(suiteName: own)!
        XCTAssertTrue(settings.bool(forKey: "setupWizardCompleted.v1"), "the settings come over anyway")
        XCTAssertEqual(settings.stringArray(forKey: "skills.disabled.v1"), [locked], "still the folder the app works in")
        XCTAssertEqual(AppPaths.resolveSupport(in: base), legacy)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked)
        XCTAssertTrue(launch(own, legacyDomain: legacyDomain))
        XCTAssertNil(LaunchMigration.failure)
        let current = DataFolderMigration.currentFolder(in: base)
        XCTAssertEqual(settings.stringArray(forKey: "skills.disabled.v1"), [current.appendingPathComponent(skill).path])
        XCTAssertEqual(AppPaths.resolveSupport(in: base), current)
    }

    func testANewInstallHasNothingToMoveAndNoNotice() {
        let own = "vision.launch.own.\(UUID().uuidString)"
        suites.append(own)
        XCTAssertTrue(launch(own, legacyDomain: "vision.launch.none.\(UUID().uuidString)") {
            XCTFail("nothing to move: no need to ask"); return true
        })
        XCTAssertTrue(DataFolderMigration.isSettled(DataFolderMigration.currentFolder(in: base)))
        XCTAssertFalse(UserDefaults(suiteName: own)!.bool(forKey: LegacySettingsImport.noticePendingKey))
    }

    func testTheNoticeSaysWhatCameAlongAndWhatMacOSAsksAgain() {
        let notice = LaunchMigration.renameNotice
        XCTAssertTrue(notice.hasPrefix("DSH is now Vision — your chats, settings and keys came with you."), notice)
        for permission in ["Screen Recording", "Accessibility", "Automation", "Keychain"] {
            XCTAssertTrue(notice.contains(permission), permission)
        }
    }
}
