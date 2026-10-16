import XCTest
@testable import VisionHarnessCore

// The first launch as Vision brings the data folder and settings of the build from before the rename (DSH) over.
// Everything here runs on temporary folders and throwaway settings suites, never the real ones.

/// A fake `~/Library/Application Support` holding an earlier build's data folder.
private final class SupportFixture {
    let base: URL
    var legacy: URL { DataFolderMigration.legacyFolder(in: base) }
    var current: URL { DataFolderMigration.currentFolder(in: base) }
    var staging: URL { base.appendingPathComponent(DataFolderMigration.stagingName, isDirectory: true) }
    let fm = FileManager.default

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vision-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func cleanup() {
        // A test may have locked a file; unlock everything before removing.
        if let walker = fm.enumerator(atPath: base.path) {
            while let relative = walker.nextObject() as? String {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(relative).path)
            }
        }
        try? fm.removeItem(at: base)
    }

    @discardableResult
    func write(_ relative: String, in root: URL, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func readJSON(_ relative: String, in root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// An earlier build's data folder, as the app writes it: chats, the task queue, a skill draft, the vault's
    /// index, user skills, a plain chat's scratch folder with the user's own files, a hidden file, a link.
    func seedLegacy() throws {
        let old = legacy.path
        try write("conversations/A.json", in: legacy, json([
            "session": ["id": "A", "title": "Plain chat", "updatedAt": 781_234_567.25, "scratch": old + "/Chats/B"],
            "items": [["seq": 1, "kind": "user", "text": "Read \(old)/Chats/A/notes.txt please", "isError": false,
                       "at": 781_234_567.5]],
        ]))
        try write("conversations/P.json", in: legacy, json([
            "session": ["id": "P", "title": "Project chat", "cwd": "/Users/pat/project", "updatedAt": 781_234_000.0],
            "items": [],
        ]))
        try write("conversations/broken.json", in: legacy, Data("not json {\(old)}".utf8))
        try write("task-queue.json", in: legacy, json([
            "tasks": [["id": "T1", "title": "Plain task", "status": "queued", "enteredAt": 781_234_100.0,
                       "cwd": "/Users/pat/project", "workFolder": old + "/Chats/B", "log": []],
                      ["id": "T2", "title": "Old task", "status": "complete", "enteredAt": 781_234_200.0,
                       "cwd": old + "/Chats/C", "log": [["at": 781_234_300.0, "kind": "note", "text": "in \(old)"]]]],
        ]))
        try write("skill-drafts/d1/draft.json", in: legacy, json([
            "scope": "project", "projectPath": old + "/Chats/B", "source": "agent", "createdAt": 0,
        ]))
        try write("skill-drafts/d1/SKILL.md", in: legacy, Data("---\nname: d1\ndescription: x\n---\n".utf8))
        try write("vault.json", in: legacy, Data("[]".utf8))
        try write("skills/alpha/SKILL.md", in: legacy, Data("---\nname: alpha\ndescription: Use when alpha.\n---\nA".utf8))
        // The user's own file in a plain chat's folder: never rewritten, even though it looks like app state.
        try write("Chats/B/settings.json", in: legacy, json(["cwd": old + "/Chats/B"]))
        try write(".hidden", in: legacy, Data("h".utf8))
        try fm.createSymbolicLink(atPath: legacy.appendingPathComponent("skills-link").path, withDestinationPath: "skills")
    }

    func snapshot(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let walker = try XCTUnwrap(fm.enumerator(atPath: root.path))
        while let relative = walker.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            let attributes = try fm.attributesOfItem(atPath: path)
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?: out[relative] = try Data(contentsOf: URL(fileURLWithPath: path))
            case .typeSymbolicLink?: out[relative] = Data(("link:" + (try fm.destinationOfSymbolicLink(atPath: path))).utf8)
            default: out[relative] = Data("dir".utf8)
            }
        }
        return out
    }
}

final class DataFolderPathRewriterTests: XCTestCase {
    private let rewriter = DataFolderPathRewriter(
        from: URL(fileURLWithPath: "/Users/pat/Library/Application Support/DSHMac", isDirectory: true),
        to: URL(fileURLWithPath: "/Users/pat/Library/Application Support/Vision", isDirectory: true))

    func testPathsIntoTheOldFolderMoveAndNothingElseDoes() {
        XCTAssertEqual(rewriter.rewrite("/Users/pat/Library/Application Support/DSHMac"),
                       "/Users/pat/Library/Application Support/Vision")
        XCTAssertEqual(rewriter.rewrite("/Users/pat/Library/Application Support/DSHMac/skills/a/SKILL.md"),
                       "/Users/pat/Library/Application Support/Vision/skills/a/SKILL.md")
        XCTAssertNil(rewriter.rewrite("/Users/pat/Library/Application Support/DSHMacOther/x"), "a sibling folder")
        XCTAssertNil(rewriter.rewrite("/Users/pat/project"))
        XCTAssertNil(rewriter.rewrite("see /Users/pat/Library/Application Support/DSHMac/x"), "not a path on its own")
        XCTAssertNil(rewriter.rewrite(""))
    }

    func testFileURLsMoveToo() {
        XCTAssertEqual(rewriter.rewrite("file:///Users/pat/Library/Application%20Support/DSHMac/Chats/B/"),
                       "file:///Users/pat/Library/Application%20Support/Vision/Chats/B/")
        XCTAssertEqual(rewriter.rewrite("file:///Users/pat/Library/Application%20Support/DSHMac"),
                       "file:///Users/pat/Library/Application%20Support/Vision")
        XCTAssertNil(rewriter.rewrite("file:///Users/pat/Library/Application%20Support/DSHMacOther/"))
    }

    func testAPathInsideASettingsKeyMoves() {
        XCTAssertEqual(rewriter.rewriteEmbedded("code.state./Users/pat/Library/Application Support/DSHMac/Chats/B"),
                       "code.state./Users/pat/Library/Application Support/Vision/Chats/B")
        XCTAssertEqual(rewriter.rewriteEmbedded("code.state./Users/pat/Library/Application Support/DSHMac"),
                       "code.state./Users/pat/Library/Application Support/Vision")
        XCTAssertNil(rewriter.rewriteEmbedded("code.state./Users/pat/Library/Application Support/DSHMacOther"))
        XCTAssertNil(rewriter.rewriteEmbedded("code.state./Users/pat/project"))
    }

    func testSettingsValuesMoveInsideListsDictionariesAndJSON() throws {
        let old = "/Users/pat/Library/Application Support/DSHMac"
        let new = "/Users/pat/Library/Application Support/Vision"
        XCTAssertEqual(rewriter.rewrite(value: [old + "/skills/a", "/elsewhere"]) as? [String], [new + "/skills/a", "/elsewhere"])
        XCTAssertNil(rewriter.rewrite(value: ["/elsewhere"]))
        XCTAssertNil(rewriter.rewrite(value: 42))
        XCTAssertNil(rewriter.rewrite(value: Date()))
        let dictionary = try XCTUnwrap(rewriter.rewrite(value: ["k": old, old + "/x": 1]) as? [String: Any])
        XCTAssertEqual(dictionary["k"] as? String, new)
        XCTAssertEqual(dictionary[new + "/x"] as? Int, 1)

        // JSONEncoder escapes slashes; the rewritten JSON still decodes to the moved paths.
        struct Selection: Codable, Equatable { var pinned: [String]; var auto: Bool }
        let encoded = try JSONEncoder().encode(["chat": Selection(pinned: [old + "/skills/a/SKILL.md"], auto: false)])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\\/"))
        let moved = try XCTUnwrap(rewriter.rewrite(value: encoded) as? Data)
        XCTAssertEqual(try JSONDecoder().decode([String: Selection].self, from: moved),
                       ["chat": Selection(pinned: [new + "/skills/a/SKILL.md"], auto: false)])

        XCTAssertNil(rewriter.rewrite(value: Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])), "data that isn't JSON is left alone")
        XCTAssertNil(rewriter.rewrite(value: try JSONEncoder().encode(["x": "/elsewhere"])))
    }

    func testOnlyTheNamedJSONKeysMove() throws {
        let old = "/Users/pat/Library/Application Support/DSHMac"
        let tree: [String: Any] = ["cwd": old + "/a", "text": old + "/b", "nested": [["scratch": old, "cwd": 3]]]
        let moved = try XCTUnwrap(rewriter.rewrite(json: tree, keys: ["cwd", "scratch"]) as? [String: Any])
        XCTAssertEqual(moved["cwd"] as? String, "/Users/pat/Library/Application Support/Vision/a")
        XCTAssertEqual(moved["text"] as? String, old + "/b")
        let nested = try XCTUnwrap(moved["nested"] as? [[String: Any]])
        XCTAssertEqual(nested[0]["scratch"] as? String, "/Users/pat/Library/Application Support/Vision")
        XCTAssertEqual(nested[0]["cwd"] as? Int, 3)
        XCTAssertNil(rewriter.rewrite(json: ["text": old], keys: ["cwd"]))
    }
}

final class DataFolderMigrationTests: XCTestCase {
    private var fx: SupportFixture!
    override func setUpWithError() throws { fx = try SupportFixture() }
    override func tearDown() { fx.cleanup() }

    private func migrate(stopAfter step: DataFolderMigration.Step? = nil) -> DataFolderMigration.Outcome {
        DataFolderMigration.run(in: fx.base, fileManager: fx.fm, now: Date(timeIntervalSince1970: 1_800_000_000),
                                stopAfter: step)
    }

    /// The new folder holds the old one's data with the stored paths moved, and nothing the user wrote changed.
    private func assertMigrated(file: StaticString = #filePath, line: UInt = #line) throws {
        let old = fx.legacy.path, new = fx.current.path
        XCTAssertTrue(DataFolderMigration.isSettled(fx.current), file: file, line: line)
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.staging.path), "no staging folder left", file: file, line: line)
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.current.appendingPathComponent(DataFolderMigration.stagedMarkerName).path),
                       file: file, line: line)

        let chat = try fx.readJSON("conversations/A.json", in: fx.current)
        let session = try XCTUnwrap(chat["session"] as? [String: Any])
        XCTAssertEqual(session["scratch"] as? String, new + "/Chats/B", file: file, line: line)
        XCTAssertEqual(session["updatedAt"] as? Double, 781_234_567.25, file: file, line: line)
        let items = try XCTUnwrap(chat["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["text"] as? String, "Read \(old)/Chats/A/notes.txt please",
                       "what was said in a chat stays as it was said", file: file, line: line)
        XCTAssertEqual(items.first?["isError"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(items.first?["at"] as? Double, 781_234_567.5, file: file, line: line)

        let queue = try fx.readJSON("task-queue.json", in: fx.current)
        let tasks = try XCTUnwrap(queue["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks[0]["workFolder"] as? String, new + "/Chats/B", file: file, line: line)
        XCTAssertEqual(tasks[0]["cwd"] as? String, "/Users/pat/project", file: file, line: line)
        XCTAssertEqual(tasks[1]["cwd"] as? String, new + "/Chats/C", file: file, line: line)
        let log = try XCTUnwrap(tasks[1]["log"] as? [[String: Any]])
        XCTAssertEqual(log.first?["text"] as? String, "in \(old)", file: file, line: line)

        XCTAssertEqual(try fx.readJSON("skill-drafts/d1/draft.json", in: fx.current)["projectPath"] as? String,
                       new + "/Chats/B", file: file, line: line)
        XCTAssertEqual(try fx.readJSON("Chats/B/settings.json", in: fx.current)["cwd"] as? String, old + "/Chats/B",
                       "the user's own files are never rewritten", file: file, line: line)

        // Everything else is byte for byte the original.
        let before = try fx.snapshot(fx.legacy).filter { $0.key != DataFolderMigration.legacyNoteName }
        let after = try fx.snapshot(fx.current)
        let rewritten: Set = ["conversations/A.json", "task-queue.json", "skill-drafts/d1/draft.json"]
        XCTAssertEqual(Set(after.keys), Set(before.keys).union([DataFolderMigration.markerName]), file: file, line: line)
        for (path, data) in before where !rewritten.contains(path) {
            XCTAssertEqual(after[path], data, path, file: file, line: line)
        }
        XCTAssertEqual(try fx.fm.destinationOfSymbolicLink(atPath: fx.current.appendingPathComponent("skills-link").path),
                       "skills", "a link is copied as a link", file: file, line: line)
        XCTAssertEqual(AppPaths.resolveSupport(in: fx.base, fileManager: fx.fm), fx.current, file: file, line: line)
    }

    func testWithNoEarlierBuildTheNewFolderIsSettledAtOnce() throws {
        XCTAssertFalse(DataFolderMigration.isPending(in: fx.base))
        XCTAssertEqual(migrate(), .started)
        XCTAssertTrue(DataFolderMigration.isSettled(fx.current))
        XCTAssertNil(DataFolderMigration.settledMarker(of: fx.current)?.migratedFrom)
        XCTAssertEqual(AppPaths.resolveSupport(in: fx.base, fileManager: fx.fm), fx.current)
        XCTAssertEqual(migrate(), .alreadySettled)

        // An old folder turning up later (the old app run again) never takes over.
        try fx.seedLegacy()
        XCTAssertEqual(migrate(), .alreadySettled)
        XCTAssertEqual(AppPaths.resolveSupport(in: fx.base, fileManager: fx.fm), fx.current)
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.current.appendingPathComponent("vault.json").path))
    }

    func testTheEarlierBuildsFolderIsCopiedCheckedRewrittenAndSettled() throws {
        try fx.seedLegacy()
        let original = try fx.snapshot(fx.legacy)
        XCTAssertTrue(DataFolderMigration.isPending(in: fx.base))
        XCTAssertEqual(AppPaths.resolveSupport(in: fx.base, fileManager: fx.fm), fx.legacy,
                       "until it is settled the app works where the data is")

        guard case .migrated(let report) = migrate() else { return XCTFail("not migrated") }
        XCTAssertEqual(report.items, original.count)
        XCTAssertEqual(report.rewrittenFiles, 3)
        XCTAssertNil(report.setAside)
        try assertMigrated()

        // The old folder is left exactly as it was, plus a note saying where everything went.
        var now = try fx.snapshot(fx.legacy)
        let note = String(decoding: try XCTUnwrap(now.removeValue(forKey: DataFolderMigration.legacyNoteName)), as: UTF8.self)
        XCTAssertEqual(now, original)
        XCTAssertTrue(note.contains("now called Vision"), note)
        XCTAssertTrue(note.contains(fx.current.path), note)

        let marker = try XCTUnwrap(DataFolderMigration.settledMarker(of: fx.current))
        XCTAssertEqual(marker.migratedFrom, fx.legacy.path)
        XCTAssertEqual(marker.items, original.count)
        XCTAssertEqual(marker.rewrittenFiles, 3)
        XCTAssertFalse(DataFolderMigration.isPending(in: fx.base))
    }

    func testRunningAgainChangesNothing() throws {
        try fx.seedLegacy()
        guard case .migrated = migrate() else { return XCTFail("not migrated") }
        try fx.write("conversations/new.json", in: fx.current, Data("{}".utf8))
        let settled = try fx.snapshot(fx.current)
        let legacy = try fx.snapshot(fx.legacy)

        XCTAssertEqual(migrate(), .alreadySettled)
        XCTAssertEqual(migrate(), .alreadySettled)
        XCTAssertEqual(try fx.snapshot(fx.current), settled)
        XCTAssertEqual(try fx.snapshot(fx.legacy), legacy)
    }

    func testACrashAtAnyStepLeavesTheOriginalAloneAndTheNextLaunchFinishes() throws {
        for step in DataFolderMigration.Step.allCases {
            fx.cleanup()
            fx = try SupportFixture()
            try fx.seedLegacy()
            let original = try fx.snapshot(fx.legacy)

            guard case .failed = migrate(stopAfter: step) else { return XCTFail("\(step): didn't stop") }
            XCTAssertEqual(try fx.snapshot(fx.legacy), original, "\(step): the original is untouched")
            let settled = step == .marked
            XCTAssertEqual(AppPaths.resolveSupport(in: fx.base, fileManager: fx.fm), settled ? fx.current : fx.legacy,
                           "\(step): the app works in the old folder until the new one is settled")

            switch migrate() {
            case .migrated: XCTAssertFalse(settled, "\(step)")
            case .alreadySettled: XCTAssertTrue(settled, "\(step)")
            default: XCTFail("\(step): the next launch didn't finish")
            }
            try assertMigrated()
            XCTAssertEqual(migrate(), .alreadySettled, "\(step)")
        }
    }

    func testTwoLaunchesAtOnceTakeTurns() throws {
        try fx.seedLegacy()
        final class Outcomes: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [DataFolderMigration.Outcome] = []
            func add(_ outcome: DataFolderMigration.Outcome) { lock.withLock { list.append(outcome) } }
            var all: [DataFolderMigration.Outcome] { lock.withLock { list } }
        }
        let collected = Outcomes()
        let base = fx.base
        DispatchQueue.concurrentPerform(iterations: 3) { _ in collected.add(DataFolderMigration.run(in: base)) }
        let outcomes = collected.all
        XCTAssertEqual(outcomes.filter { if case .migrated = $0 { return true } else { return false } }.count, 1, "\(outcomes)")
        XCTAssertEqual(outcomes.filter { $0 == .alreadySettled }.count, 2, "\(outcomes)")
        try assertMigrated()
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.base.appendingPathComponent(DataFolderMigration.lockName).path),
                       "no lock file left once settled")
    }

    func testAnUnfinishedCopyIsMadeAgainFromWhatTheOldFolderHoldsNow() throws {
        try fx.seedLegacy()
        guard case .failed = migrate(stopAfter: .moved) else { return XCTFail("didn't stop") }
        // The app kept working in the old folder (it wasn't settled), so that holds the newest chat.
        try fx.write("conversations/later.json", in: fx.legacy, fx.json(["session": ["id": "later"], "items": []]))

        guard case .migrated = migrate() else { return XCTFail("not migrated") }
        XCTAssertTrue(fx.fm.fileExists(atPath: fx.current.appendingPathComponent("conversations/later.json").path))
        try assertMigrated()
    }

    func testAFinishedCopyWhoseOriginalWasDeletedIsKept() throws {
        try fx.seedLegacy()
        guard case .failed = migrate(stopAfter: .moved) else { return XCTFail("didn't stop") }
        try fx.fm.removeItem(at: fx.legacy)

        XCTAssertEqual(migrate(), .started)
        XCTAssertTrue(DataFolderMigration.isSettled(fx.current))
        XCTAssertEqual(DataFolderMigration.settledMarker(of: fx.current)?.migratedFrom, fx.legacy.path)
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.current.appendingPathComponent(DataFolderMigration.stagedMarkerName).path))
        XCTAssertTrue(fx.fm.fileExists(atPath: fx.current.appendingPathComponent("vault.json").path))
    }

    func testAFolderAlreadyUsingTheNewNameIsSetAsideNotLost() throws {
        try fx.seedLegacy()
        try fx.write("mine.txt", in: fx.current, Data("keep me".utf8))

        guard case .migrated(let report) = migrate() else { return XCTFail("not migrated") }
        let aside = try XCTUnwrap(report.setAside)
        XCTAssertTrue(aside.hasPrefix("Vision (set aside "), aside)
        XCTAssertEqual(try Data(contentsOf: fx.base.appendingPathComponent(aside).appendingPathComponent("mine.txt")),
                       Data("keep me".utf8))
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.current.appendingPathComponent("mine.txt").path))
        XCTAssertEqual(DataFolderMigration.settledMarker(of: fx.current)?.setAside, aside)
        try assertMigrated()
    }

    func testAnEmptyFolderUsingTheNewNameIsJustReplaced() throws {
        try fx.seedLegacy()
        try fx.write(".DS_Store", in: fx.current, Data("finder".utf8))
        guard case .migrated(let report) = migrate() else { return XCTFail("not migrated") }
        XCTAssertNil(report.setAside)
        try assertMigrated()
    }

    func testAnOldFolderThatCantBeCopiedLeavesEverythingAsItWas() throws {
        try fx.seedLegacy()
        let locked = fx.legacy.appendingPathComponent("skills/alpha/SKILL.md").path
        try fx.fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? fx.fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
        guard getuid() != 0 else { throw XCTSkip("root reads anything") }

        guard case .failed = migrate() else { return XCTFail("a copy that can't read a file must not settle") }
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.current.path))
        XCTAssertFalse(fx.fm.fileExists(atPath: fx.staging.path))
        XCTAssertEqual(AppPaths.resolveSupport(in: fx.base, fileManager: fx.fm), fx.legacy)

        try fx.fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked)
        guard case .migrated = migrate() else { return XCTFail("the next launch didn't finish") }
        try assertMigrated()
    }

    func testAnOldFolderThatIsALinkIsCopiedByWhatItHolds() throws {
        let real = fx.base.appendingPathComponent("elsewhere/DSHMac-real", isDirectory: true)
        try fx.write("vault.json", in: real, Data("[]".utf8))
        try fx.fm.createSymbolicLink(at: fx.legacy, withDestinationURL: real)

        guard case .migrated = migrate() else { return XCTFail("not migrated") }
        XCTAssertEqual(try Data(contentsOf: fx.current.appendingPathComponent("vault.json")), Data("[]".utf8))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fx.fm.fileExists(atPath: fx.current.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertNil(try? fx.fm.destinationOfSymbolicLink(atPath: fx.current.path), "a real folder, not a copy of the link")
    }

    func testTheInventoryListsLinksWithoutFollowingThemAndSeesADifferentSize() throws {
        let a = fx.base.appendingPathComponent("a", isDirectory: true)
        let b = fx.base.appendingPathComponent("b", isDirectory: true)
        try fx.write("dir/file.txt", in: a, Data("12345".utf8))
        try fx.fm.createSymbolicLink(atPath: a.appendingPathComponent("loop").path, withDestinationPath: ".")
        try fx.fm.copyItem(at: a, to: b)
        let left = try XCTUnwrap(DataFolderMigration.inventory(a, fx.fm))
        XCTAssertEqual(Set(left.keys), ["dir", "dir/file.txt", "loop"], "a link to its own folder is not walked into")
        XCTAssertEqual(left["loop"]?.link, ".")
        XCTAssertEqual(left, DataFolderMigration.inventory(b, fx.fm))

        try Data("1234".utf8).write(to: b.appendingPathComponent("dir/file.txt"))
        XCTAssertNotEqual(left, DataFolderMigration.inventory(b, fx.fm))
    }
}

final class LegacySettingsImportTests: XCTestCase {
    private var legacyName = ""
    private var targetName = ""
    private var legacy: UserDefaults!
    private var target: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let old = "/Users/pat/Library/Application Support/DSHMac"
    private let new = URL(fileURLWithPath: "/Users/pat/Library/Application Support/Vision", isDirectory: true)

    override func setUp() {
        super.setUp()
        legacyName = "vision.test.legacy.\(UUID().uuidString)"
        targetName = "vision.test.target.\(UUID().uuidString)"
        legacy = UserDefaults(suiteName: legacyName)
        target = UserDefaults(suiteName: targetName)
    }

    override func tearDown() {
        legacy.removePersistentDomain(forName: legacyName)
        target.removePersistentDomain(forName: targetName)
        super.tearDown()
    }

    private var legacyDomain: [String: Any]? { legacy.persistentDomain(forName: legacyName) }
    private var targetDomain: [String: Any]? { target.persistentDomain(forName: targetName) }

    private func importNow() -> LegacySettingsImport.Outcome {
        LegacySettingsImport.run(legacy: legacyDomain, into: target, existing: targetDomain, now: now)
    }

    private func seed() throws {
        legacy.set(try JSONEncoder().encode(["routes"]), forKey: "providers.v2")
        legacy.set("Spark|qwen", forKey: "activeModel.v2")
        legacy.set(true, forKey: "setupWizardCompleted.v1")
        legacy.set(14.5, forKey: "editor.fontSize")
        legacy.set([old + "/skills/a/SKILL.md", "/Users/pat/.claude/skills/b/SKILL.md"], forKey: "skills.disabled.v1")
        legacy.set(Date(timeIntervalSince1970: 1_700_000_000), forKey: "some.date")
        legacy.set(Data("{}".utf8), forKey: "code.state.\(old)/Chats/B")
    }

    func testEverySettingComesOverOnceAndTheOldFileIsLeftAlone() throws {
        try seed()
        let before = try XCTUnwrap(legacyDomain)
        XCTAssertEqual(importNow(), .imported(copied: 7, kept: 0))
        XCTAssertEqual(target.string(forKey: "activeModel.v2"), "Spark|qwen")
        XCTAssertTrue(target.bool(forKey: "setupWizardCompleted.v1"))
        XCTAssertEqual(target.double(forKey: "editor.fontSize"), 14.5)
        XCTAssertEqual(target.data(forKey: "providers.v2"), try JSONEncoder().encode(["routes"]))
        XCTAssertEqual(target.object(forKey: "some.date") as? Date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(target.stringArray(forKey: "skills.disabled.v1")?.first, old + "/skills/a/SKILL.md",
                       "paths follow the data folder only once it is settled")
        XCTAssertTrue(target.bool(forKey: LegacySettingsImport.noticePendingKey))
        XCTAssertEqual(target.object(forKey: LegacySettingsImport.importedKey) as? Date, now)
        XCTAssertEqual(legacyDomain as NSDictionary?, before as NSDictionary)

        // Once: later changes to the old file don't come over again.
        legacy.set("Other|model", forKey: "activeModel.v2")
        target.removeObject(forKey: LegacySettingsImport.noticePendingKey)
        XCTAssertEqual(importNow(), .alreadyDone)
        XCTAssertEqual(target.string(forKey: "activeModel.v2"), "Spark|qwen")
        XCTAssertFalse(target.bool(forKey: LegacySettingsImport.noticePendingKey))
    }

    func testASettingTheNewFileAlreadyHasIsKept() throws {
        try seed()
        target.set("Vision|model", forKey: "activeModel.v2")
        XCTAssertEqual(importNow(), .imported(copied: 6, kept: 1))
        XCTAssertEqual(target.string(forKey: "activeModel.v2"), "Vision|model")
    }

    func testWithNothingToImportThereIsNoNotice() {
        XCTAssertEqual(LegacySettingsImport.run(legacy: nil, into: target, existing: targetDomain, now: now), .nothingToImport)
        XCTAssertEqual(LegacySettingsImport.run(legacy: [:], into: target, existing: targetDomain, now: now), .alreadyDone)
        XCTAssertFalse(target.bool(forKey: LegacySettingsImport.noticePendingKey))
        XCTAssertNotNil(target.object(forKey: LegacySettingsImport.importedKey))
    }

    func testACrashBeforeTheMarkerCopiesAgainAndChangesNothing() throws {
        try seed()
        _ = importNow()
        let afterFirst = try XCTUnwrap(targetDomain)
        target.removeObject(forKey: LegacySettingsImport.importedKey)   // as if the app died before writing it

        XCTAssertEqual(importNow(), .imported(copied: 0, kept: 7))
        var again = try XCTUnwrap(targetDomain)
        again[LegacySettingsImport.importedKey] = afterFirst[LegacySettingsImport.importedKey]
        XCTAssertEqual(again as NSDictionary, afterFirst as NSDictionary)
    }

    func testPathsFollowTheDataFolderOnceItIsSettledAndOnlyOnce() throws {
        try seed()
        let selection = try JSONEncoder().encode(["chat": ["pinned": [old + "/skills/a/SKILL.md"]]])
        legacy.set(selection, forKey: "skills.session.v1")
        _ = importNow()

        // Not settled yet: the app is still working in the old folder, so its paths stay.
        XCTAssertEqual(LegacySettingsImport.movePaths(in: target, existing: targetDomain, settled: nil, newFolder: new, now: now), 0)
        XCTAssertNil(target.object(forKey: LegacySettingsImport.pathsMovedKey))
        XCTAssertEqual(target.stringArray(forKey: "skills.disabled.v1")?.first, old + "/skills/a/SKILL.md")

        let marker = DataFolderMigration.Marker(migratedFrom: old, at: now)
        XCTAssertEqual(LegacySettingsImport.movePaths(in: target, existing: targetDomain, settled: marker, newFolder: new, now: now), 3)
        XCTAssertEqual(target.stringArray(forKey: "skills.disabled.v1"),
                       [new.path + "/skills/a/SKILL.md", "/Users/pat/.claude/skills/b/SKILL.md"])
        let session = try JSONDecoder().decode([String: [String: [String]]].self,
                                               from: try XCTUnwrap(target.data(forKey: "skills.session.v1")))
        XCTAssertEqual(session["chat"]?["pinned"], [new.path + "/skills/a/SKILL.md"])
        XCTAssertNotNil(target.data(forKey: "code.state.\(new.path)/Chats/B"))
        XCTAssertNil(target.object(forKey: "code.state.\(old)/Chats/B"))
        XCTAssertEqual(target.string(forKey: "activeModel.v2"), "Spark|qwen")
        XCTAssertEqual(target.data(forKey: "providers.v2"), try JSONEncoder().encode(["routes"]))

        // Once.
        target.set([old + "/later"], forKey: "skills.disabled.v1")
        XCTAssertEqual(LegacySettingsImport.movePaths(in: target, existing: targetDomain, settled: marker, newFolder: new, now: now), 0)
        XCTAssertEqual(target.stringArray(forKey: "skills.disabled.v1"), [old + "/later"])
    }

    func testANewStartHasNoPathsToMove() throws {
        target.set(["/x"], forKey: "skills.disabled.v1")
        let marker = DataFolderMigration.Marker(migratedFrom: nil, at: now)
        XCTAssertEqual(LegacySettingsImport.movePaths(in: target, existing: targetDomain, settled: marker, newFolder: new, now: now), 0)
        XCTAssertNotNil(target.object(forKey: LegacySettingsImport.pathsMovedKey))
        XCTAssertEqual(target.stringArray(forKey: "skills.disabled.v1"), ["/x"])
    }
}
