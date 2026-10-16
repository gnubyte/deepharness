import XCTest
@testable import VisionHarnessCore

/// Projects set up before the rename keep their `.dsh/` folder and `DSH.md` (they may be committed): the app reads
/// them forever, next to `.vision/` and `VISION.md`, writes only the new names, and never moves a user's files.
final class LegacyProjectFolderTests: XCTestCase {
    private var fx: SkillFixture!
    override func setUpWithError() throws { fx = try SkillFixture() }
    override func tearDownWithError() throws { fx.cleanup() }

    func testSkillsInBothFoldersAreReadAndTheNewFolderWins() throws {
        try fx.skill(".dsh/skills/old-one", name: "old-one", description: "Use when old.")
        try fx.skill(".vision/skills/new-one", name: "new-one", description: "Use when new.")
        try fx.skill(".dsh/skills/twin", name: "twin", description: "from .dsh")
        try fx.skill(".vision/skills/twin", name: "twin", description: "from .vision")

        let skills = SkillCatalog.loadAll(project: fx.project, locations: fx.locations)
        XCTAssertEqual(Set(skills.filter { !$0.shadowed }.map(\.name)), ["old-one", "new-one", "twin"])
        XCTAssertEqual(SkillCatalog.load(project: fx.project, locations: fx.locations).count, 3)
        XCTAssertEqual(skills.first { $0.name == "twin" && !$0.shadowed }?.description, "from .vision")
        XCTAssertEqual(skills.first { $0.name == "twin" && $0.shadowed }?.description, "from .dsh")
        for skill in skills {
            XCTAssertEqual(skill.origin, .vision, skill.name)
            XCTAssertEqual(skill.scope, .project, skill.name)
            XCTAssertTrue(skill.isOwned, "a skill in the old folder can still be edited in place")
        }
    }

    func testNewProjectSkillsAreWrittenToTheNewFolderOnly() throws {
        try fx.skill(".dsh/skills/old-one", name: "old-one", description: "Use when old.")
        let landed = try SkillManager.create(text: "---\nname: fresh\ndescription: Use when fresh.\n---\nDo it.",
                                             scope: .project, projectRoot: fx.project, locations: fx.locations)
        XCTAssertEqual(landed.path, fx.project.appendingPathComponent(".vision/skills/fresh/SKILL.md").path)
        let old = try FileManager.default.contentsOfDirectory(atPath: fx.project.appendingPathComponent(".dsh/skills").path)
        XCTAssertEqual(old, ["old-one"], "nothing written to, or moved out of, the old folder")

        // Exporting in this app's own layout writes the new folder too.
        let skills = SkillCatalog.load(project: fx.project, locations: fx.locations)
        let out = fx.base.appendingPathComponent("export")
        try SkillExporter.write(skills, format: .vision, into: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(".vision/skills/old-one/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".dsh").path))
    }

    func testAnImportFromEitherFolderIsThisAppsOwn() throws {
        try fx.skill(".dsh/skills/alpha", name: "alpha", description: "Use when alpha.")
        let plan = try SkillImporter.scan(fx.project.appendingPathComponent(".dsh/skills/alpha"))
        defer { SkillImporter.dispose(plan) }
        XCTAssertEqual(plan.candidates.map(\.skill.origin), [.vision])
    }

    func testAgentFilesInBothFoldersAreReadAndTheNewFolderWins() throws {
        try fx.write(".dsh/agents/old-helper.md", "---\ndescription: Old helper\n---\nHelp.")
        try fx.write(".vision/agents/new-helper.md", "---\ndescription: New helper\n---\nHelp.")
        try fx.write(".claude/agents/twin.md", "---\ndescription: from .claude\n---\nA.")
        try fx.write(".dsh/agents/twin.md", "---\ndescription: from .dsh\n---\nB.")
        try fx.write(".vision/agents/twin.md", "---\ndescription: from .vision\n---\nC.")

        let catalog = AgentCatalog.load(workspace: fx.project, userDirectories: [])
        XCTAssertEqual(catalog.find("old-helper")?.description, "Old helper")
        XCTAssertEqual(catalog.find("new-helper")?.description, "New helper")
        XCTAssertEqual(catalog.find("twin")?.description, "from .vision")

        // A new file in either folder is noticed.
        let before = AgentCatalog.stamp(workspace: fx.project, userDirectories: [])
        try fx.write(".dsh/agents/later.md", "---\ndescription: Later\n---\nL.")
        XCTAssertNotEqual(AgentCatalog.stamp(workspace: fx.project, userDirectories: []), before)
    }

    func testPluginsInBothFoldersAreReadTheNewFolderFirst() {
        let folders = PluginLoader.directories(project: fx.project).map(\.path)
        XCTAssertEqual(Array(folders.prefix(2)), [fx.project.appendingPathComponent(".vision/plugins").path,
                                                  fx.project.appendingPathComponent(".dsh/plugins").path])
        XCTAssertEqual(folders.last, AppPaths.plugins.path)
    }

    func testBothInstructionFilesAreReadTheNewOneFirst() throws {
        try fx.write("DSH.md", "Old rules.")
        try fx.write("VISION.md", "New rules.")
        let files = ProjectContext.instructionFiles(root: fx.project)
        XCTAssertEqual(files.map(\.label), ["VISION.md", "DSH.md"])

        try FileManager.default.removeItem(at: fx.project.appendingPathComponent("VISION.md"))
        XCTAssertEqual(ProjectContext.instructionFiles(root: fx.project).map(\.text), ["Old rules."])
    }
}
