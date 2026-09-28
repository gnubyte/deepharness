import XCTest
@testable import DSHCore

/// A minimal STORED zip writer, so a test can build an archive with hostile
/// paths that `zip` itself would refuse to create.
enum TinyZip {
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
    static func le(_ v: UInt32, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) }) }

    static func make(_ entries: [(String, String)]) -> Data {
        var out = Data(), central = Data()
        for (name, content) in entries {
            let nameData = Data(name.utf8), body = Data(content.utf8)
            let offset = UInt32(out.count), crc = crc32(body)
            var local = Data()
            local += le(0x04034b50, 4) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2)
            local += le(crc, 4) + le(UInt32(body.count), 4) + le(UInt32(body.count), 4) + le(UInt32(nameData.count), 2) + le(0, 2)
            out += local + nameData + body
            central += le(0x02014b50, 4) + le(20, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2)
            central += le(crc, 4) + le(UInt32(body.count), 4) + le(UInt32(body.count), 4) + le(UInt32(nameData.count), 2)
            central += le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(offset, 4) + nameData
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += le(0x06054b50, 4) + le(0, 2) + le(0, 2) + le(UInt32(entries.count), 2) + le(UInt32(entries.count), 2)
        out += le(UInt32(central.count), 4) + le(cdOffset, 4) + le(0, 2)
        return out
    }
}

final class SkillTransferTests: XCTestCase {
    var fx: SkillFixture!
    override func setUpWithError() throws { fx = try SkillFixture() }
    override func tearDownWithError() throws { fx.cleanup() }

    /// A repo laid out the way people actually publish skills.
    private func makeRepo() throws -> URL {
        let repo = fx.base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try fx.skill("skills/pdf-tools", name: "pdf-tools", description: "Use when working with PDFs.", in: repo)
        try fx.write("skills/pdf-tools/scripts/extract.py", in: repo, "print('hi')")
        try fx.write("skills/pdf-tools/reference.md", in: repo, "Reference")
        try fx.skill(".claude/skills/review", name: "review", description: "Use when reviewing code.", in: repo)
        try fx.write(".claude/commands/deploy.md", in: repo, "---\ndescription: Ship it\n---\nShip $ARGUMENTS")
        try fx.write(".claude/agents/reviewer.md", in: repo, "---\nname: reviewer\n---\nAgent")
        try fx.write(".cursor/rules/lore.mdc", in: repo, "---\ndescription: Canon\nglobs:\n  - \"docs/**\"\nalwaysApply: false\n---\nCanon.")
        try fx.write(".cursorrules", in: repo, "Old style Cursor rules.")
        try fx.write("CLAUDE.md", in: repo, "# Project\nBe careful.")
        try fx.write("node_modules/junk/SKILL.md", in: repo, "---\nname: junk\ndescription: should be skipped\n---\nx")
        return repo
    }

    func testScanFindsSkillsRulesCommandsAndKnowledgeButNotJunk() throws {
        let plan = try SkillImporter.scan(try makeRepo())
        let byName = Dictionary(uniqueKeysWithValues: plan.candidates.map { ($0.name, $0) })
        XCTAssertNotNil(byName["pdf-tools"]); XCTAssertNotNil(byName["review"]); XCTAssertNotNil(byName["deploy"])
        XCTAssertNotNil(byName["lore"]); XCTAssertNotNil(byName["cursorrules"]); XCTAssertNotNil(byName["claude-md"])
        XCTAssertNil(byName["junk"], "dependency folders are skipped")
        XCTAssertTrue(byName["pdf-tools"]!.hasScripts)
        XCTAssertEqual(byName["pdf-tools"]!.fileCount, 3)
        XCTAssertFalse(byName["review"]!.hasScripts)
        XCTAssertEqual(byName["review"]!.origin, .claude)
        XCTAssertEqual(byName["deploy"]!.kind, .command)
        XCTAssertTrue(byName["cursorrules"]!.isInstructionFile && byName["cursorrules"]!.skill.alwaysApply)
        XCTAssertTrue(plan.notes.contains { $0.contains("subagent") }, plan.notes.joined())
    }

    func testImportActiveAndAsDraft() throws {
        let plan = try SkillImporter.scan(try makeRepo())
        let pick = Set(plan.candidates.filter { ["pdf-tools", "lore", "deploy"].contains($0.name) }.map(\.id))
        let active = try SkillImporter.perform(plan, selecting: pick, scope: .project, projectRoot: fx.project, asDraft: false, locations: fx.locations)
        XCTAssertEqual(active.imported.count, 3)
        let live = Dictionary(uniqueKeysWithValues: SkillCatalog.load(project: fx.project, locations: fx.locations).map { ($0.name, $0) })
        XCTAssertEqual(live["pdf-tools"]?.origin, .dsh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live["pdf-tools"]!.directory.appendingPathComponent("scripts/extract.py").path), "bundled files come along")
        XCTAssertEqual(live["lore"]?.globs, ["docs/**"])
        XCTAssertEqual(live["deploy"]?.modelInvocable, false)

        // Same import again: conflicts are renamed, not overwritten.
        let again = try SkillImporter.perform(plan, selecting: pick, scope: .project, projectRoot: fx.project, asDraft: false, conflict: .rename, locations: fx.locations)
        XCTAssertEqual(again.imported.count, 3)
        XCTAssertTrue(again.imported.contains { $0.path.contains("pdf-tools-2") })
        let strict = try SkillImporter.perform(plan, selecting: pick, scope: .project, projectRoot: fx.project, asDraft: false, conflict: .fail, locations: fx.locations)
        XCTAssertEqual(strict.skipped.count, 3)

        // As drafts, nothing becomes active.
        let before = SkillCatalog.load(project: fx.project, locations: fx.locations).count
        let staged = try SkillImporter.perform(plan, selecting: Set(plan.candidates.map(\.id)), scope: .user, projectRoot: nil, asDraft: true, locations: fx.locations)
        XCTAssertEqual(staged.drafts.count, plan.candidates.count)
        XCTAssertEqual(SkillCatalog.load(project: fx.project, locations: fx.locations).count, before)
        XCTAssertTrue(staged.drafts.allSatisfy { $0.source == "import" && $0.note?.contains("Imported from") == true })
    }

    func testImportFromSingleFilesAndSkillFolders() throws {
        let mdc = try fx.write("loose/style.mdc", "---\ndescription: Style\nalwaysApply: true\n---\nUse tabs.")
        let plan = try SkillImporter.scan(mdc)
        XCTAssertEqual(plan.candidates.count, 1)
        XCTAssertEqual(plan.candidates[0].kind, .rule); XCTAssertTrue(plan.candidates[0].skill.alwaysApply)

        let cursorrules = try fx.write("loose2/.cursorrules", "Legacy rules.")
        let p2 = try SkillImporter.scan(cursorrules)
        XCTAssertTrue(p2.candidates[0].isInstructionFile)

        try fx.skill("one/my-skill", name: "my-skill", description: "Use when solo.")
        XCTAssertEqual(try SkillImporter.scan(fx.project.deletingLastPathComponent().appendingPathComponent("project/one/my-skill/SKILL.md")).candidates.map(\.name), ["my-skill"])
        XCTAssertThrowsError(try SkillImporter.scan(fx.base.appendingPathComponent("missing")))
        XCTAssertThrowsError(try SkillImporter.scan(try fx.write("x.txt", "hello")))
    }

    func testSymlinksAreNeverFollowedIntoAnImport() throws {
        let repo = fx.base.appendingPathComponent("repo2")
        try fx.skill("s", name: "s", description: "Use when linked.", in: repo)
        let secret = try fx.write("secret.txt", "TOP SECRET")
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("s/leak.txt"), withDestinationURL: secret)
        let plan = try SkillImporter.scan(repo.appendingPathComponent("s"))
        _ = try SkillImporter.perform(plan, selecting: Set(plan.candidates.map(\.id)), scope: .user, projectRoot: nil, asDraft: false, locations: fx.locations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.locations.userSkills.appendingPathComponent("s/leak.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.locations.userSkills.appendingPathComponent("s/SKILL.md").path))
    }

    func testOversizedSkillFolderIsRefused() throws {
        let repo = fx.base.appendingPathComponent("big")
        try fx.skill("huge", name: "huge", description: "Use when huge.", in: repo)
        let blob = Data(count: SkillFiles.maxFileBytes + 1)
        try blob.write(to: repo.appendingPathComponent("huge/blob.bin"))
        let plan = try SkillImporter.scan(repo)
        let r = try SkillImporter.perform(plan, selecting: Set(plan.candidates.map(\.id)), scope: .user, projectRoot: nil, asDraft: false, locations: fx.locations)
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertTrue(r.skipped["huge"]?.contains("MB") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.locations.userSkills.appendingPathComponent("huge").path), "nothing half-copied")
    }

    // MARK: Zip

    func testExportPortableZipThenImportItBack() throws {
        try fx.skill(".dsh/skills/alpha", name: "alpha", description: "Use when alpha.", body: "ALPHA")
        try fx.write(".dsh/skills/alpha/ref/notes.md", "notes")
        try fx.write(".cursor/rules/beta.mdc", "---\ndescription: Beta rule\nglobs: [\"b/**\"]\n---\nBETA")
        let skills = SkillCatalog.load(project: fx.project, locations: fx.locations)
        let zip = fx.base.appendingPathComponent("out.zip")
        try SkillExporter.zip(skills, format: .portable, to: zip)
        let listing = try SkillProcess.run("/usr/bin/unzip", ["-Z1", zip.path]).out
        XCTAssertTrue(listing.contains("alpha/SKILL.md")); XCTAssertTrue(listing.contains("alpha/ref/notes.md")); XCTAssertTrue(listing.contains("beta/SKILL.md"))

        let plan = try SkillImporter.scan(zip)
        defer { SkillImporter.dispose(plan) }
        XCTAssertEqual(Set(plan.candidates.map(\.name)), ["alpha", "beta"])
        let beta = plan.candidates.first { $0.name == "beta" }!
        XCTAssertEqual(beta.skill.globs, ["b/**"], "rule metadata survives the round trip")
    }

    func testHostileZipPathsAreRefused() throws {
        for evil in ["../evil/SKILL.md", "/abs/SKILL.md", "ok/../../escape.txt"] {
            let zip = fx.base.appendingPathComponent("evil.zip")
            try TinyZip.make([(evil, "---\nname: evil\ndescription: x\n---\nbody")]).write(to: zip)
            XCTAssertThrowsError(try SkillImporter.scan(zip), evil) { XCTAssertTrue(($0 as? SkillError)?.errorDescription?.contains("unsafe") ?? false) }
        }
        let good = fx.base.appendingPathComponent("good.zip")
        try TinyZip.make([("my-skill/SKILL.md", "---\nname: my-skill\ndescription: Use when zipped by hand.\n---\nbody")]).write(to: good)
        let plan = try SkillImporter.scan(good)
        XCTAssertEqual(plan.candidates.map(\.name), ["my-skill"])
        SkillImporter.dispose(plan)
        XCTAssertThrowsError(try SkillImporter.scan(try fx.write("notazip.zip", "not a zip")))
    }

    func testRemoteScanRejectsNonHTTPS() async {
        for bad in ["http://example.com/x.zip", "file:///etc/passwd", "ext::sh -c id", "git@github.com:a/b.git", ""] {
            do { _ = try await SkillImporter.scan(remote: bad); XCTFail("accepted \(bad)") }
            catch { XCTAssertTrue(error is SkillError, "\(bad): \(error)") }
        }
    }

    // MARK: Export layouts

    func testExportLayoutsAreReadableByTheirTools() throws {
        try fx.skill(".dsh/skills/alpha", name: "alpha", description: "Use when alpha.", body: "ALPHA")
        try fx.skill(".dsh/skills/withfiles", name: "withfiles", description: "Use when files.", body: "F")
        try fx.write(".dsh/skills/withfiles/scripts/run.sh", "echo")
        try fx.write(".claude/commands/ship.md", "---\ndescription: Ship\n---\nShip it")
        let skills = SkillCatalog.load(project: fx.project, locations: fx.locations)

        // Claude: lands where Claude Code looks, and DSH reads it back.
        let claudeRoot = fx.base.appendingPathComponent("out-claude")
        try SkillExporter.write(skills, format: .claude, into: claudeRoot)
        let back = SkillCatalog.load(project: claudeRoot, locations: SkillLocations(home: fx.base.appendingPathComponent("nohome"), appSupport: fx.base.appendingPathComponent("nosupport")))
        XCTAssertEqual(Set(back.map(\.name)), ["alpha", "withfiles", "ship"])
        XCTAssertTrue(back.allSatisfy { $0.origin == .claude })
        XCTAssertEqual(back.first { $0.name == "ship" }?.modelInvocable, false)

        // Cursor: plain skills become .mdc rules; skills with bundled files stay folders.
        let cursorRoot = fx.base.appendingPathComponent("out-cursor")
        try SkillExporter.write(skills, format: .cursor, into: cursorRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursorRoot.appendingPathComponent(".cursor/rules/alpha.mdc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursorRoot.appendingPathComponent(".cursor/skills/withfiles/scripts/run.sh").path))
        let mdc = SkillDocument.parse(try String(contentsOf: cursorRoot.appendingPathComponent(".cursor/rules/alpha.mdc"), encoding: .utf8))
        XCTAssertEqual(mdc["description"], "Use when alpha."); XCTAssertEqual(mdc.bool("alwaysApply"), false)
        XCTAssertNil(mdc["name"], "Cursor rules carry no name field")

        for (format, sub) in [(ExportFormat.agents, ".agents/skills/alpha/SKILL.md"), (.dsh, ".dsh/skills/alpha/SKILL.md"), (.portable, "alpha/SKILL.md")] {
            let root = fx.base.appendingPathComponent("out-\(format.rawValue)")
            try SkillExporter.write(skills, format: format, into: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(sub).path), "\(format)")
        }
    }

    func testExportConflictPolicies() throws {
        try fx.skill(".dsh/skills/alpha", name: "alpha", description: "Use when alpha.")
        let skills = SkillCatalog.load(project: fx.project, locations: fx.locations)
        let root = fx.base.appendingPathComponent("target")
        try SkillExporter.write(skills, format: .claude, into: root)
        XCTAssertThrowsError(try SkillExporter.write(skills, format: .claude, into: root, conflict: .fail))
        try SkillExporter.write(skills, format: .claude, into: root, conflict: .replace)
        let renamed = try SkillExporter.write(skills, format: .claude, into: root, conflict: .rename)
        XCTAssertTrue(renamed[0].path.hasSuffix("alpha-2"))
        try SkillExporter.write(skills, format: .cursor, into: root)
        XCTAssertThrowsError(try SkillExporter.write(skills, format: .cursor, into: root, conflict: .fail))
    }
}
